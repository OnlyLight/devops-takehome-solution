// quote-api: tiny HTTP service used as the workload for the GitOps / placement / load-test parts.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// workDuration is the CPU cost of one /api/quote request on an unthrottled core.
const workDuration = 100 * time.Millisecond

// workIters is the number of chained SHA-256 rounds that take about workDuration of CPU on this machine.
// It is measured once at start-up (see calibrate). Each request does exactly this much WORK, not "spin for
// 100ms of wall clock": under a CPU limit (CFS throttling) the same work takes longer, so latency rises and
// throughput per pod is capped by CPU, as with a real CPU-bound handler. A wall-clock spin would hide that.
var workIters = calibrate()

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

// hashLoop does n chained SHA-256 rounds: a fixed amount of real CPU work (not a sleep).
func hashLoop(n int) {
	buf := []byte("quote-api")
	for i := 0; i < n; i++ {
		sum := sha256.Sum256(buf)
		buf = sum[:]
	}
	runtime.KeepAlive(buf)
}

// calibrate returns how many hashLoop rounds take about workDuration of CPU. It times many short batches and
// keeps the FASTEST one: throttling or preemption can only make a batch slower, so the minimum is the closest
// to the unthrottled speed. WORK_ITERATIONS overrides it (tests, or pinning the work across nodes).
func calibrate() int {
	if v, err := strconv.Atoi(os.Getenv("WORK_ITERATIONS")); err == nil && v > 0 {
		return v
	}
	const batch = 100000 // ~10ms: long enough for a coarse clock (Windows), short enough to fit a CFS quota slice
	best := time.Duration(math.MaxInt64)
	for i := 0; i < 12; i++ {
		start := time.Now()
		hashLoop(batch)
		if d := time.Since(start); d > 0 && d < best { // d == 0: the clock did not tick during the batch
			best = d
		}
	}
	iters := 0
	if best < time.Duration(math.MaxInt64) {
		iters = int(float64(batch) * float64(workDuration) / float64(best))
	} else {
		// Clock too coarse for short batches: time one long run instead (error bounded by the clock tick).
		const long = 1000000
		start := time.Now()
		hashLoop(long)
		if d := time.Since(start); d > 0 {
			iters = int(float64(long) * float64(workDuration) / float64(d))
		}
	}
	// Never return something absurd (a stalled machine at start-up must not skew the work for the pod's lifetime).
	const lo, hi = 10000, 50000000
	if iters < lo {
		iters = lo
	}
	if iters > hi {
		iters = hi
	}
	return iters
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
		hashLoop(workIters)
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

	log.Printf("calibrated: %d SHA-256 rounds per /api/quote request (~%v of CPU)", workIters, workDuration)
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
