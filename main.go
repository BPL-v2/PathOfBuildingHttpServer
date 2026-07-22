package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[pob-server] ")

	if err := godotenv.Load(); err != nil && !os.IsNotExist(err) {
		log.Fatalf("failed to load .env: %v", err)
	}

	cfg := config{
		listenAddr:       envOr("POB_LISTEN_ADDR", ":8080"),
		luajitBin:        envOr("LUAJIT_BIN", "luajit"),
		entry:            envOr("POB_ENTRY", "CharacterImportService.lua"),
		startTimeout:     envDurationSecOr("POB_START_TIMEOUT_SEC", 120*time.Second),
		jobTimeout:       envDurationSecOr("POB_JOB_TIMEOUT_SEC", 120*time.Second),
		queueTimeout:     envDurationSecOr("POB_QUEUE_TIMEOUT_SEC", 30*time.Second),
		idleTimeout:      envDurationSecOr("POB_IDLE_TIMEOUT_SEC", 300*time.Second),
		maxJobsPerWorker: envIntOr("POB_MAX_JOBS_PER_WORKER", 500),
		kafkaBroker:      envOr("KAFKA_BROKER", ""),
		debugXMLDiff:     envBoolOr("POB_DEBUG_XML_DIFF", false),
		debugXMLDiffDir:  envOr("POB_DEBUG_XML_DIFF_DIR", "xml-diffs"),
	}

	prewarm := envBoolOr("POB_PREWARM", true)
	if !prewarm {
		log.Print("prewarm disabled: workers are spawned per request, response times include PoB boot")
	}
	// By default prewarm only keeps workers warm across requests; the pool
	// still starts idle and spawns nothing until the first real request (see
	// newPool). Set this to spawn the full worker set immediately at boot
	// instead, at the cost of a startup CPU/memory spike.
	warmOnStartup := envBoolOr("POB_WARM_ON_STARTUP", false)

	games := []struct {
		name        string
		rootEnv     string
		defaultRoot string
	}{
		{"poe1", "POB_POE1_ROOT", "PathOfBuilding"},
		{"poe2", "POB_POE2_ROOT", "PathOfBuilding-PoE2"},
	}

	var flavors []*flavor
	for _, game := range games {
		root := envOr(game.rootEnv, game.defaultRoot)
		if !isPobRoot(root) {
			log.Printf("[%s] disabled: %s does not contain src/Launch.lua", game.name, root)
			continue
		}
		flavors = append(flavors, &flavor{name: game.name, pobRoot: root})
	}
	if len(flavors) == 0 {
		log.Fatal("no PoB runtime found; set POB_POE1_ROOT / POB_POE2_ROOT or run scripts/pull-pob-runtimes.sh")
	}

	p := newPool(envIntOr("POB_WORKERS", 4), prewarm, cfg, flavors)
	mux := http.NewServeMux()
	for _, f := range flavors {
		mux.Handle("/"+f.name+"/", instrumentHandler(f.name, p.handler(f)))
	}
	mux.Handle("/healthz", instrumentHandler("healthz", healthHandler(p)))
	prometheus.MustRegister(newWorkerCollector(p))
	mux.Handle("/metrics", instrumentHandler("metrics", promhttp.Handler()))

	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	workerCtx, cancelWorkers := context.WithCancel(context.Background())

	var slots sync.WaitGroup
	if p.prewarm {
		if warmOnStartup {
			p.touch()
		}
		for range p.size {
			slots.Add(1)
			go p.runSlot(workerCtx, &slots)
		}
		if cfg.idleTimeout > 0 {
			go p.runReaper(workerCtx)
		}
	}

	if cfg.kafkaBroker != "" {
		go runKafkaConsumer(workerCtx, p, cfg.kafkaBroker)
	} else {
		log.Print("KAFKA_BROKER not set: Kafka consumer disabled, HTTP-only mode")
	}

	server := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-signalCtx.Done()
		// Drain in-flight requests first, then tear the workers down.
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		server.Shutdown(shutdownCtx)
		cancelWorkers()
	}()

	log.Printf("listening on %s", cfg.listenAddr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("http server failed: %v", err)
	}
	slots.Wait()
	log.Print("shut down cleanly")
}
