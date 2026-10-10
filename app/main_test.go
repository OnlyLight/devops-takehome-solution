package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func get(t *testing.T, s *server, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	s.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestHealthzAlwaysOK(t *testing.T) {
	s := newServer() // not ready yet: liveness must not depend on readiness
	if got := get(t, s, "/healthz").Code; got != http.StatusOK {
		t.Fatalf("/healthz = %d, want 200", got)
	}
}

func TestReadyzFollowsReadyFlag(t *testing.T) {
	s := newServer()
	if got := get(t, s, "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("/readyz before ready = %d, want 503", got)
	}
	s.ready.Store(true)
	if got := get(t, s, "/readyz").Code; got != http.StatusOK {
		t.Fatalf("/readyz when ready = %d, want 200", got)
	}
	s.ready.Store(false) // what SIGTERM does
	if got := get(t, s, "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("/readyz while draining = %d, want 503", got)
	}
}

func TestQuoteReturnsJSONAndBurnsCPU(t *testing.T) {
	s := newServer()
	start := time.Now()
	rec := get(t, s, "/api/quote")
	elapsed := time.Since(start)

	if rec.Code != http.StatusOK {
		t.Fatalf("/api/quote = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["quote"] == "" {
		t.Fatalf("bad body %q: %v", rec.Body.String(), err)
	}
	if elapsed < workDuration {
		t.Fatalf("took %v, want >= %v of simulated work", elapsed, workDuration)
	}
}

func TestMetricsExposeCustomCounterAndHTTPSeries(t *testing.T) {
	s := newServer()
	get(t, s, "/api/quote")
	get(t, s, "/api/quote")

	out := get(t, s, "/metrics").Body.String()
	for _, want := range []string{
		"quote_requests_total 2",
		`http_requests_total{code="200",path="/api/quote"} 2`,
		"http_request_duration_seconds_bucket",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
}
