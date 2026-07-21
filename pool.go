package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const maxRequestBody = 32 << 20

type response struct {
	status int
	body   []byte
}

// workerProc is one luajit worker process. Workers are persistent: a single
// process handles many sequential jobs (see jobsDone/retirement in the
// pool), not just one - respawning the whole PoB runtime (tree/mod/item
// data) per request is what made the old one-shot-per-request design slow.
type workerProc struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	ready    chan struct{} // closed when READY is seen
	resp     chan response // buffered(1), receives the next job's response
	exited   chan struct{} // closed when stdout reaches EOF (process is gone)
	jobsDone int           // requests served so far; only touched by the current owner
}

func (w *workerProc) kill() {
	if w.cmd.Process != nil {
		// Negative pid: the worker gets its own process group at spawn.
		syscall.Kill(-w.cmd.Process.Pid, syscall.SIGKILL)
	}
}

// retire closes stdin so the worker sees EOF on its next readJob and exits
// cleanly, instead of being offered another job.
func (w *workerProc) retire() {
	w.stdin.Close()
	go func() {
		select {
		case <-w.exited:
		case <-time.After(10 * time.Second):
			w.kill()
		}
	}()
}

// execute sends one job to the worker and waits for its response. The
// worker remains alive afterwards, ready for another job, until the caller
// retires it.
func (w *workerProc) execute(endpoint string, body []byte, timeout time.Duration) (response, error) {
	if _, err := fmt.Fprintf(w.stdin, "%s %d\n", endpoint, len(body)); err != nil {
		return response{}, fmt.Errorf("writing job header: %w", err)
	}
	if _, err := w.stdin.Write(body); err != nil {
		return response{}, fmt.Errorf("writing job body: %w", err)
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case resp := <-w.resp:
		w.jobsDone++
		return resp, nil
	case <-w.exited:
		return response{}, errors.New("worker exited before responding")
	case <-timer.C:
		w.kill()
		return response{}, errors.New("worker timed out")
	}
}

// flavor is one game's PoB checkout. Workers boot exactly one checkout, so
// every worker belongs to a flavor, but all flavors share the pool's slots.
type flavor struct {
	name    string
	pobRoot string

	warm     chan *workerProc
	pending  atomic.Int64 // requests currently waiting for a warm worker
	slots    atomic.Int64 // pool slots currently committed to this flavor
	spawned  atomic.Int64
	failures atomic.Int64

	// Live worker pids and their last-sampled CPU time, for /metrics.
	// cpuAccum carries the CPU time of exited workers so the per-game CPU
	// counter stays monotonic.
	mu       sync.Mutex
	liveCPU  map[int]float64
	cpuAccum float64
}

func (f *flavor) logf(format string, args ...any) {
	log.Printf("["+f.name+"] "+format, args...)
}

// pool maintains size pre-initialized workers shared across all flavors.
type pool struct {
	size    int
	prewarm bool
	cfg     config
	flavors []*flavor

	// In cold mode (prewarm off) this semaphore caps concurrent on-demand
	// workers at the pool size, matching warm mode's memory ceiling.
	coldSlots chan struct{}

	// Idle scale-down: lastRequest is touched by every request; wake unparks
	// slots that stopped respawning while the pool was idle.
	lastRequest atomic.Int64
	wake        chan struct{}
}

func newPool(size int, prewarm bool, cfg config, flavors []*flavor) *pool {
	p := &pool{
		size:      size,
		prewarm:   prewarm,
		cfg:       cfg,
		flavors:   flavors,
		coldSlots: make(chan struct{}, size),
		wake:      make(chan struct{}, size),
	}
	for _, f := range flavors {
		f.warm = make(chan *workerProc, size)
		f.liveCPU = map[int]float64{}
	}
	// lastRequest is left at its zero value, so the pool starts out already
	// "idle" (decades past any idleTimeout) rather than warming up eagerly.
	// runSlot's waitUntilActive parks every slot until the first real
	// request calls touch(), so workers only spin up on actual demand -
	// no eager memory/CPU spike at boot (e.g. during a rolling deploy where
	// old and new pods briefly overlap).
	return p
}

// pickFlavor decides which game the next worker should boot: the flavor with
// the most unserved demand (waiting requests minus committed slots), falling
// back to keeping the flavors evenly staffed when nobody is waiting.
func (p *pool) pickFlavor() *flavor {
	var best *flavor
	var bestScore, bestSlots int64
	for _, f := range p.flavors {
		slots := f.slots.Load()
		score := f.pending.Load() - slots
		if best == nil || score > bestScore || (score == bestScore && slots < bestSlots) {
			best, bestScore, bestSlots = f, score, slots
		}
	}
	return best
}

// touch records request activity and unparks idle slots.
func (p *pool) touch() {
	p.lastRequest.Store(time.Now().UnixNano())
	for {
		select {
		case p.wake <- struct{}{}:
		default:
			return
		}
	}
}

func (p *pool) idleFor() time.Duration {
	return time.Since(time.Unix(0, p.lastRequest.Load()))
}

// waitUntilActive parks a slot while the pool is idle, so no worker is
// respawned until the next request. Returns false when ctx is cancelled.
func (p *pool) waitUntilActive(ctx context.Context) bool {
	if p.cfg.idleTimeout <= 0 {
		return true
	}
	for p.idleFor() > p.cfg.idleTimeout {
		select {
		case <-ctx.Done():
			return false
		case <-p.wake:
		case <-time.After(time.Second):
		}
	}
	return true
}

// runReaper shuts down warm workers once the pool has been idle too long.
func (p *pool) runReaper(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		if p.idleFor() > p.cfg.idleTimeout {
			p.drainIdleWorkers()
		}
	}
}

func (p *pool) drainIdleWorkers() {
	for _, f := range p.flavors {
		for drained := false; !drained; {
			select {
			case w := <-f.warm:
				f.logf("no requests for %s, shutting down idle warm worker pid %d",
					p.cfg.idleTimeout, w.cmd.Process.Pid)
				// Closing stdin makes the worker read EOF and exit cleanly;
				// its slot then parks in waitUntilActive.
				w.stdin.Close()
				go func() {
					select {
					case <-w.exited:
					case <-time.After(10 * time.Second):
						w.kill()
					}
				}()
			default:
				drained = true
			}
		}
	}
}

// readStdout demultiplexes a worker's stdout into protocol events and log lines.
func (f *flavor) readStdout(w *workerProc, r io.Reader) {
	br := bufio.NewReaderSize(r, 64*1024)
	for {
		line, err := br.ReadString('\n')
		trimmed := strings.TrimRight(line, "\r\n")
		switch {
		case trimmed == "#POB READY":
			close(w.ready)
		case strings.HasPrefix(trimmed, "#POB RESPONSE "):
			var status, length int
			if _, scanErr := fmt.Sscanf(trimmed, "#POB RESPONSE %d %d", &status, &length); scanErr != nil {
				f.logf("malformed response header %q: %v", trimmed, scanErr)
				break
			}
			body := make([]byte, length)
			if _, readErr := io.ReadFull(br, body); readErr != nil {
				f.logf("truncated response body: %v", readErr)
				break
			}
			w.resp <- response{status: status, body: body}
		case trimmed != "":
			f.logf("%s", trimmed)
		}
		if err != nil {
			close(w.exited)
			return
		}
	}
}

func (f *flavor) logLines(r io.Reader) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	for scanner.Scan() {
		if line := scanner.Text(); line != "" {
			f.logf("%s", line)
		}
	}
	if err := scanner.Err(); err != nil {
		f.logf("stderr read error: %v", err)
	}
}

func (p *pool) spawn(f *flavor) (*workerProc, error) {
	cmd := exec.Command(p.cfg.luajitBin, p.cfg.entry, "--pob-root", f.pobRoot)
	// Own process group so kill() cannot hit anything else.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	f.spawned.Add(1)

	w := &workerProc{
		cmd:    cmd,
		stdin:  stdin,
		ready:  make(chan struct{}),
		resp:   make(chan response, 1),
		exited: make(chan struct{}),
	}
	pid := cmd.Process.Pid
	f.mu.Lock()
	f.liveCPU[pid] = 0
	f.mu.Unlock()

	go f.readStdout(w, stdout)
	go f.logLines(stderr)
	go func() {
		<-w.exited
		// The process is a zombie until Wait; sample its final CPU time
		// while /proc is still readable.
		if _, cpu, err := readProcStat(pid); err == nil {
			f.mu.Lock()
			f.liveCPU[pid] = cpu
			f.mu.Unlock()
		}
		cmd.Wait()
		f.mu.Lock()
		f.cpuAccum += f.liveCPU[pid]
		delete(f.liveCPU, pid)
		f.mu.Unlock()
	}()
	return w, nil
}

// runSlot keeps one pool slot filled: pick a flavor, spawn a worker, wait
// until it is warm, offer it to requests, wait until it has died, repeat.
func (p *pool) runSlot(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()
	backoff := time.Second
	for ctx.Err() == nil {
		if !p.waitUntilActive(ctx) {
			return
		}
		f := p.pickFlavor()
		f.slots.Add(1)
		if !p.fillSlot(ctx, f, &backoff) {
			f.slots.Add(-1)
			return
		}
		f.slots.Add(-1)
	}
}

// fillSlot runs one worker lifecycle for the given flavor. Returns false when
// ctx is cancelled.
func (p *pool) fillSlot(ctx context.Context, f *flavor, backoff *time.Duration) bool {
	started := time.Now()
	w, err := p.spawn(f)
	if err != nil {
		f.logf("failed to spawn worker: %v", err)
		f.failures.Add(1)
		if !sleepCtx(ctx, *backoff) {
			return false
		}
		*backoff = min(*backoff*2, 30*time.Second)
		return true
	}

	startTimer := time.NewTimer(p.cfg.startTimeout)
	select {
	case <-w.ready:
		startTimer.Stop()
	case <-w.exited:
		startTimer.Stop()
		f.logf("worker exited before becoming ready")
		f.failures.Add(1)
		if !sleepCtx(ctx, *backoff) {
			return false
		}
		*backoff = min(*backoff*2, 30*time.Second)
		return true
	case <-startTimer.C:
		f.logf("worker did not become ready within %s, killing it", p.cfg.startTimeout)
		w.kill()
		f.failures.Add(1)
		return true
	case <-ctx.Done():
		startTimer.Stop()
		w.kill()
		return false
	}
	*backoff = time.Second
	bootDuration.WithLabelValues(f.name).Observe(time.Since(started).Seconds())
	f.logf("worker pid %d warm after %s", w.cmd.Process.Pid, time.Since(started).Round(time.Millisecond))

	select {
	case f.warm <- w:
	case <-ctx.Done():
		w.kill()
		return false
	}

	// Handed off (or idle in the warm channel). Respawn once it is gone.
	select {
	case <-w.exited:
		return true
	case <-ctx.Done():
		w.kill()
		return false
	}
}

// acquireCold spawns a worker on demand and waits for it to boot PoB, so the
// caller's response time includes the full startup cost. Used when prewarm
// is disabled.
func (p *pool) acquireCold(ctx context.Context, f *flavor) (*workerProc, func(), error) {
	slotTimer := time.NewTimer(p.cfg.queueTimeout)
	defer slotTimer.Stop()
	select {
	case p.coldSlots <- struct{}{}:
	case <-slotTimer.C:
		return nil, nil, errors.New("all cold worker slots busy")
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	}
	freeSlot := func() { <-p.coldSlots }

	started := time.Now()
	w, err := p.spawn(f)
	if err != nil {
		f.failures.Add(1)
		freeSlot()
		return nil, nil, fmt.Errorf("spawning worker: %w", err)
	}
	// Cold workers aren't pooled for reuse (that's the whole point of
	// prewarm being off), so always retire after the one job.
	release := func() {
		w.retire()
		freeSlot()
	}

	startTimer := time.NewTimer(p.cfg.startTimeout)
	defer startTimer.Stop()
	select {
	case <-w.ready:
		bootDuration.WithLabelValues(f.name).Observe(time.Since(started).Seconds())
		f.logf("cold worker pid %d ready after %s", w.cmd.Process.Pid, time.Since(started).Round(time.Millisecond))
		return w, release, nil
	case <-w.exited:
		f.failures.Add(1)
		freeSlot()
		return nil, nil, errors.New("worker exited before becoming ready")
	case <-startTimer.C:
		w.kill()
		f.failures.Add(1)
		freeSlot()
		return nil, nil, errors.New("worker did not become ready in time")
	case <-ctx.Done():
		w.kill()
		freeSlot()
		return nil, nil, ctx.Err()
	}
}

func (p *pool) acquire(ctx context.Context, f *flavor) (*workerProc, error) {
	// pending steers freed slots toward this flavor while we wait.
	f.pending.Add(1)
	defer f.pending.Add(-1)
	timer := time.NewTimer(p.cfg.queueTimeout)
	defer timer.Stop()
	for {
		select {
		case w := <-f.warm:
			select {
			case <-w.exited:
				f.logf("discarding worker that died while idle")
				continue
			default:
				return w, nil
			}
		case <-timer.C:
			return nil, errors.New("no warm PoB worker available")
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

// releaseWorker returns a used warm worker to the pool for reuse, unless it
// has already died or has served its quota of jobs - in which case it is
// retired so fillSlot spawns a fresh replacement.
func (p *pool) releaseWorker(f *flavor, w *workerProc) {
	select {
	case <-w.exited:
		return
	default:
	}
	if p.cfg.maxJobsPerWorker > 0 && w.jobsDone >= p.cfg.maxJobsPerWorker {
		f.logf("worker pid %d retiring after %d jobs", w.cmd.Process.Pid, w.jobsDone)
		w.retire()
		return
	}
	select {
	case f.warm <- w:
	default:
		// f.warm is already at capacity; shouldn't normally happen since
		// each worker has exactly one owning slot, but don't leak it.
		w.retire()
	}
}

func (p *pool) handler(f *flavor) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			http.Error(rw, "Only POST supported.", http.StatusMethodNotAllowed)
			return
		}
		endpoint := "import-character"
		if strings.HasSuffix(req.URL.Path, "/update-config") {
			endpoint = "update-config"
		}
		body, err := io.ReadAll(http.MaxBytesReader(rw, req.Body, maxRequestBody))
		if err != nil {
			http.Error(rw, "Failed to read request body.", http.StatusBadRequest)
			return
		}

		var w *workerProc
		if p.prewarm {
			p.touch()
			w, err = p.acquire(req.Context(), f)
		} else {
			var release func()
			w, release, err = p.acquireCold(req.Context(), f)
			if release != nil {
				defer release()
			}
		}
		if err != nil {
			jobsTotal.WithLabelValues(f.name, endpoint, "busy").Inc()
			f.logf("%s rejected: %v", endpoint, err)
			http.Error(rw, "PoB backend is busy, try again shortly.", http.StatusServiceUnavailable)
			return
		}
		jobStart := time.Now()
		resp, err := w.execute(endpoint, body, p.cfg.jobTimeout)
		jobDuration.WithLabelValues(f.name, endpoint).Observe(time.Since(jobStart).Seconds())
		if err != nil {
			jobsTotal.WithLabelValues(f.name, endpoint, "error").Inc()
			f.logf("%s failed: %v", endpoint, err)
			if p.prewarm {
				// Its state after a failed/timed-out job is untrustworthy;
				// don't hand it to another request.
				w.retire()
			}
			http.Error(rw, "PoB backend request failed.", http.StatusBadGateway)
			return
		}
		jobsTotal.WithLabelValues(f.name, endpoint, strconv.Itoa(resp.status)).Inc()
		if p.prewarm {
			p.releaseWorker(f, w)
		}
		rw.Header().Set("Content-Type", "text/plain")
		rw.WriteHeader(resp.status)
		rw.Write(resp.body)
	})
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}
