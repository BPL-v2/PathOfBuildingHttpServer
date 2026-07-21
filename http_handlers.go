package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// instrumentHandler wraps h to record request count, duration and status
// code under the given handler label.
func instrumentHandler(handlerLabel string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rec := &statusRecorder{ResponseWriter: rw, status: http.StatusOK}
		start := time.Now()
		h.ServeHTTP(rec, req)
		httpRequestDuration.WithLabelValues(handlerLabel, req.Method).Observe(time.Since(start).Seconds())
		httpRequestsTotal.WithLabelValues(handlerLabel, req.Method, strconv.Itoa(rec.status)).Inc()
	})
}

func healthHandler(p *pool) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		type gameStatus struct {
			WarmWorkers int   `json:"warmWorkers"`
			Spawned     int64 `json:"spawned"`
			Failures    int64 `json:"failures"`
		}
		games := map[string]gameStatus{}
		for _, f := range p.flavors {
			games[f.name] = gameStatus{
				WarmWorkers: len(f.warm),
				Spawned:     f.spawned.Load(),
				Failures:    f.failures.Load(),
			}
		}
		rw.Header().Set("Content-Type", "application/json")
		json.NewEncoder(rw).Encode(map[string]any{
			"poolSize": p.size,
			"games":    games,
		})
	})
}
