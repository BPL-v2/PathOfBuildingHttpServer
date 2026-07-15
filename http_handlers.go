package main

import (
	"encoding/json"
	"net/http"
)

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
