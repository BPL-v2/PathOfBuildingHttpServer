//go:build smoke

// Integration smoke tests against a already-running pob-server instance
// (e.g. the container built by the deploy workflow). Run with:
//
//	POB_SMOKE_BASE_URL=http://localhost:8080 go test -tags smoke ./... -run TestSmokeEndpoints -v
package main

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

var smokeCases = []struct {
	name    string
	path    string
	fixture string
}{
	{"poe1-import-character", "/poe1/import-character", "testdata/DoomBlastElementalist_Character.json"},
	{"poe1-update-config", "/poe1/update-config", "testdata/DoomBlastElementalist_Export.txt"},
}

func smokeBaseURL() string {
	if v := os.Getenv("POB_SMOKE_BASE_URL"); v != "" {
		return v
	}
	return "http://localhost:8080"
}

func waitForHealthy(t *testing.T) {
	t.Helper()
	url := smokeBaseURL() + "/healthz"
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
		}
		time.Sleep(2 * time.Second)
	}
	t.Fatalf("server at %s did not become healthy in time", url)
}

func TestSmokeEndpoints(t *testing.T) {
	waitForHealthy(t)

	for _, tc := range smokeCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			body, err := os.ReadFile(tc.fixture)
			if err != nil {
				t.Fatalf("reading fixture %s: %v", tc.fixture, err)
			}

			resp, err := http.Post(smokeBaseURL()+tc.path, "application/octet-stream", bytes.NewReader(body))
			if err != nil {
				t.Fatalf("POST %s: %v", tc.path, err)
			}
			defer resp.Body.Close()

			respBody, _ := io.ReadAll(resp.Body)
			if resp.StatusCode >= 400 {
				t.Fatalf("POST %s returned %d: %s", tc.path, resp.StatusCode, respBody)
			}
		})
	}
}
