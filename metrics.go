package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	jobDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "pob_job_duration_seconds",
		Help:    "Time from job dispatch to worker response.",
		Buckets: []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120},
	}, []string{"game", "endpoint"})

	jobsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "pob_jobs_total",
		Help: "Handled jobs by outcome. status is the HTTP status code, or 'busy'/'error' for pool and worker failures.",
	}, []string{"game", "endpoint", "status"})

	bootDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "pob_worker_boot_duration_seconds",
		Help:    "Time from worker spawn to READY.",
		Buckets: []float64{0.5, 1, 2, 5, 10, 30, 60, 120},
	}, []string{"game"})

	// HTTP-level metrics, covering every registered handler (including
	// /healthz and /metrics). Unlike pob_job_duration_seconds/pob_jobs_total,
	// these measure full request wall time, including time spent queueing
	// for a worker or rejected outright while the pool is busy.
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "pob_http_requests_total",
		Help: "HTTP requests handled, by handler, method and status code.",
	}, []string{"handler", "method", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "pob_http_request_duration_seconds",
		Help:    "HTTP request duration by handler and method.",
		Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120},
	}, []string{"handler", "method"})
)

// readProcStat returns the resident set size and the accumulated CPU time of
// a process, straight from /proc. Works for zombies too, so a worker's final
// CPU time can be sampled after it exits but before it is reaped.
func readProcStat(pid int) (rssBytes uint64, cpuSeconds float64, err error) {
	statm, err := os.ReadFile(fmt.Sprintf("/proc/%d/statm", pid))
	if err != nil {
		return 0, 0, err
	}
	fields := strings.Fields(string(statm))
	if len(fields) < 2 {
		return 0, 0, fmt.Errorf("unexpected statm format for pid %d", pid)
	}
	residentPages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	rssBytes = residentPages * uint64(os.Getpagesize())

	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, 0, err
	}
	// The comm field can contain spaces; fields are stable after the last ')'.
	text := string(stat)
	closing := strings.LastIndexByte(text, ')')
	if closing < 0 {
		return 0, 0, fmt.Errorf("unexpected stat format for pid %d", pid)
	}
	rest := strings.Fields(text[closing+1:])
	// rest[0] is field 3 (state); utime and stime are fields 14 and 15.
	if len(rest) < 13 {
		return 0, 0, fmt.Errorf("unexpected stat format for pid %d", pid)
	}
	utime, err := strconv.ParseUint(rest[11], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	stime, err := strconv.ParseUint(rest[12], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	const clockTicksPerSecond = 100 // USER_HZ on Linux
	cpuSeconds = float64(utime+stime) / clockTicksPerSecond
	return rssBytes, cpuSeconds, nil
}

// workerCollector reports resource usage of the live luajit workers of every
// flavor. Worker CPU time is exposed as a monotonic per-game counter: exited
// workers contribute their last-sampled CPU time via flavor.cpuAccum.
type workerCollector struct {
	pool *pool

	liveDesc  *prometheus.Desc
	warmDesc  *prometheus.Desc
	rssDesc   *prometheus.Desc
	cpuDesc   *prometheus.Desc
	spawnDesc *prometheus.Desc
	failDesc  *prometheus.Desc
}

func newWorkerCollector(p *pool) *workerCollector {
	gameLabel := []string{"game"}
	return &workerCollector{
		pool:      p,
		liveDesc:  prometheus.NewDesc("pob_workers_live", "Worker processes currently alive (warming, warm or busy).", gameLabel, nil),
		warmDesc:  prometheus.NewDesc("pob_workers_warm", "Workers ready and waiting for a job.", gameLabel, nil),
		rssDesc:   prometheus.NewDesc("pob_worker_rss_bytes", "Combined resident memory of live workers.", gameLabel, nil),
		cpuDesc:   prometheus.NewDesc("pob_worker_cpu_seconds_total", "Combined CPU time consumed by workers, including exited ones.", gameLabel, nil),
		spawnDesc: prometheus.NewDesc("pob_workers_spawned_total", "Worker processes spawned.", gameLabel, nil),
		failDesc:  prometheus.NewDesc("pob_worker_failures_total", "Workers that failed to spawn or died before becoming ready.", gameLabel, nil),
	}
}

func (c *workerCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.liveDesc
	ch <- c.warmDesc
	ch <- c.rssDesc
	ch <- c.cpuDesc
	ch <- c.spawnDesc
	ch <- c.failDesc
}

// sampleUsage reads current RSS and CPU time of all live workers from /proc,
// updating each worker's last CPU sample along the way. Returns the combined
// resident memory, the monotonic per-game CPU total and the live worker count.
func (f *flavor) sampleUsage() (rssSum uint64, cpuTotal float64, liveCount int) {
	var liveCPU float64
	f.mu.Lock()
	defer f.mu.Unlock()
	for pid := range f.liveCPU {
		liveCount++
		rss, cpu, err := readProcStat(pid)
		if err != nil {
			// Exited between tracking and reading; its last sample still
			// counts via liveCPU until it is untracked.
			liveCPU += f.liveCPU[pid]
			continue
		}
		f.liveCPU[pid] = cpu
		rssSum += rss
		liveCPU += cpu
	}
	return rssSum, f.cpuAccum + liveCPU, liveCount
}

func (c *workerCollector) Collect(ch chan<- prometheus.Metric) {
	for _, f := range c.pool.flavors {
		rssSum, cpuTotal, liveCount := f.sampleUsage()
		game := f.name
		ch <- prometheus.MustNewConstMetric(c.liveDesc, prometheus.GaugeValue, float64(liveCount), game)
		ch <- prometheus.MustNewConstMetric(c.warmDesc, prometheus.GaugeValue, float64(len(f.warm)), game)
		ch <- prometheus.MustNewConstMetric(c.rssDesc, prometheus.GaugeValue, float64(rssSum), game)
		ch <- prometheus.MustNewConstMetric(c.cpuDesc, prometheus.CounterValue, cpuTotal, game)
		ch <- prometheus.MustNewConstMetric(c.spawnDesc, prometheus.CounterValue, float64(f.spawned.Load()), game)
		ch <- prometheus.MustNewConstMetric(c.failDesc, prometheus.CounterValue, float64(f.failures.Load()), game)
	}
}
