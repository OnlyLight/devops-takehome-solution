// quote-api: tiny HTTP service used as the workload for the GitOps / placement / load-test parts.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// workDuration is the simulated CPU cost of one /api/quote request.
const workDuration = 100 * time.Millisecond

var quotes = []string{
	"The only way to do great work is to love what you do.",
	"Well begun is half done.",
	"Slow is smooth, smooth is fast.",
	"Make it work, make it right, make it fast.",
	"Whether you think you can or you think you can't, you're right.",
	"Fall seven times, stand up eight.",
	"A smooth sea never made a skilled sailor.",
	"Done is better than perfect.",
}

type server struct {
	ready atomic.Bool

	quoteTotal prometheus.Counter
	httpTotal  *prometheus.CounterVec
	httpDur    *prometheus.HistogramVec
	registry   *prometheus.Registry
}

func newServer() *server {
	s := &server{registry: prometheus.NewRegistry()}
	s.quoteTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "quote_requests_total",
		Help: "Quotes served by /api/quote.",
	})
	s.httpTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests by path and status code.",
	}, []string{"path", "code"})
	s.httpDur = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency by path.",
		Buckets: []float64{.025, .05, .1, .15, .2, .3, .5, 1, 2.5, 5},
	}, []string{"path"})
	s.registry.MustRegister(s.quoteTotal, s.httpTotal, s.httpDur)
	return s
}

// burnCPU spins on SHA-256 until d has elapsed, so the cost is real CPU (not a sleep)
// and the service saturates under load the way a CPU-bound API would.
func burnCPU(d time.Duration) {
	buf := []byte("quote-api")
	for deadline := time.Now().Add(d); time.Now().Before(deadline); {
		sum := sha256.Sum256(buf)
		buf = sum[:]
	}
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument records request count and latency. The path label is the registered pattern
// (a fixed set of routes), never the raw URL, so label cardinality stays bounded.
func (s *server) instrument(path string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		s.httpTotal.WithLabelValues(path, strconv.Itoa(rec.code)).Inc()
		s.httpDur.WithLabelValues(path).Observe(time.Since(start).Seconds())
	}
}

func (s *server) mux() *http.ServeMux {
	m := http.NewServeMux()
	m.HandleFunc("/healthz", s.instrument("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	m.HandleFunc("/readyz", s.instrument("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !s.ready.Load() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ready"))
	}))
	m.HandleFunc("/api/quote", s.instrument("/api/quote", func(w http.ResponseWriter, _ *http.Request) {
		burnCPU(workDuration)
		s.quoteTotal.Inc()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"quote": quotes[rand.Intn(len(quotes))]})
	}))
	m.Handle("/metrics", promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{}))
	return m
}

func main() {
	addr := ":" + envOr("PORT", "8080")
	s := newServer()
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.mux(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	s.ready.Store(true)
	go func() {
		log.Printf("listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	// On SIGTERM (pod eviction/drain): fail readiness first so the Service stops routing here,
	// then let in-flight requests finish. This is what keeps the reclaim drill at zero errors.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	s.ready.Store(false)
	log.Print("shutting down: readiness off, draining")
	time.Sleep(envDuration("DRAIN_DELAY", 3*time.Second))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDuration(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
