package main
import (
	"log"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type config struct {
	listenAddr       string
	luajitBin        string
	entry            string
	startTimeout     time.Duration // worker boot -> READY
	jobTimeout       time.Duration // job sent -> response
	queueTimeout     time.Duration // request waiting for a warm worker
	idleTimeout      time.Duration // no requests -> shut down warm workers (0: never)
	maxJobsPerWorker int           // requests a warm worker serves before being retired (0: unlimited)
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envIntOr(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, value, err)
	}
	return parsed
}

func envDurationSecOr(key string, fallback time.Duration) time.Duration {
	return time.Duration(envIntOr(key, int(fallback/time.Second))) * time.Second
}

func envBoolOr(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, value, err)
	}
	return parsed
}

func isPobRoot(root string) bool {
	_, err := os.Stat(filepath.Join(root, "src", "Launch.lua"))
	return err == nil
}