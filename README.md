# PoB-server

Headless Path of Building server for both:

- Path of Building
- Path of Building PoE2

to expose endpoints to create PoB exports from GGGs PoE API character data.

A Go HTTP server listens on port 8080 and dispatches requests to headless PoB
luajit worker processes over stdin/stdout pipes — there is no HTTP or socket
code on the Lua side. Workers are one-shot: each boots PoB (the expensive
part), handles exactly one request and exits, so every request runs against
fresh PoB state. The Go server keeps one shared pool of pre-warmed workers
and replaces each one as it is consumed. Each worker boots exactly one game's
PoB checkout, so the pool decides per slot which game to warm: flavors with
requests waiting get priority, otherwise the slots are split evenly across
the enabled games.

Routes:

- `POST /poe1/import-character`, `POST /poe1/update-config` → PoE1 workers
- `POST /poe2/import-character`, `POST /poe2/update-config` → PoE2 workers
- `GET /healthz` → JSON pool status per game
- `GET /metrics` → Prometheus metrics

The repository keeps the server logic here and pulls the PoB runtimes
separately for local development and CI.

## Local development

### Prerequisites

- `git`
- `go` (1.24+)
- `luajit`
- Lua modules used by the headless runtime:
  - `lua-zlib`
  - `luautf8`
  - `luafilesystem`

### Fetch or update both runtimes

Run:

```bash
./scripts/pull-pob-runtimes.sh
```

That script:

- clones or updates both upstream PoB repositories
- follows the latest default branch of each upstream repo
- uses sparse checkout so only the files needed by this server are kept locally
- writes into:
  - `PathOfBuilding/`
  - `PathOfBuilding-PoE2/`

Those directories are ignored by git in this repo.

If either local runtime checkout has uncommitted changes, the script aborts instead of overwriting them.

### Run the server

```bash
go run .
```

The server enables each game whose runtime checkout is present (it looks for
`src/Launch.lua`), so it works with one or both runtimes.

Configuration is via environment variables:

| Variable                | Default                     | Purpose                                    |
| ----------------------- | --------------------------- | ------------------------------------------ |
| `POB_LISTEN_ADDR`       | `:8080`                     | Address the Go server listens on           |
| `POB_POE1_ROOT`         | `PathOfBuilding`            | PoE1 runtime checkout                      |
| `POB_POE2_ROOT`         | `PathOfBuilding-PoE2`       | PoE2 runtime checkout                      |
| `POB_WORKERS`           | `4`                         | Pre-warmed worker pool size (shared across games) |
| `POB_PREWARM`           | `true`                      | `false`: spawn workers per request instead |
| `POB_IDLE_TIMEOUT_SEC`  | `300`                       | Shut down warm workers after this long without requests (0: keep warm forever) |
| `POB_START_TIMEOUT_SEC` | `120`                       | Max seconds for a worker to boot PoB       |
| `POB_JOB_TIMEOUT_SEC`   | `120`                       | Max seconds for a worker to handle a job   |
| `POB_QUEUE_TIMEOUT_SEC` | `30`                        | Max seconds a request waits for a worker   |
| `POB_STATS_LOG_SEC`     | `60`                        | Resource log line interval (0 disables)    |
| `LUAJIT_BIN`            | `luajit`                    | luajit executable                          |
| `POB_ENTRY`             | `CharacterImportService.lua` | Lua worker entrypoint                     |

Note on memory: each warm worker is a fully initialized PoB process, so the
pool size directly controls the resident memory footprint.

With `POB_PREWARM=false` no workers are kept warm; each request spawns its
own worker and pays the PoB boot cost (~1.1s) in its response time. The pool
size then acts as a cap on concurrent workers. Useful for comparing response
times and for memory-constrained setups where idle PoB processes are too
expensive.

In warm mode, a pool that has seen no requests for `POB_IDLE_TIMEOUT_SEC`
shuts its warm workers down (they exit cleanly) and stops respawning them, so
an idle server holds no PoB processes in memory. The next request wakes the
pool: it pays the boot cost like a cold request, and the pool stays warm
again while traffic continues.

### Monitoring

`/metrics` exposes Prometheus metrics: standard Go/process collectors for the
server itself, plus per-game worker metrics read from `/proc`:

- `pob_workers_live` / `pob_workers_warm` — worker process counts
- `pob_worker_rss_bytes` — combined resident memory of live workers
- `pob_worker_cpu_seconds_total` — combined worker CPU time (monotonic,
  includes exited workers)
- `pob_workers_spawned_total` / `pob_worker_failures_total`
- `pob_job_duration_seconds` / `pob_jobs_total{status=...}` — per endpoint
- `pob_worker_boot_duration_seconds` — spawn → READY

Without a Prometheus stack, the server also logs one resource line per pool
every `POB_STATS_LOG_SEC` seconds (default 60, 0 disables):

```
[poe1] stats: workers=2 warm=2 rss=1650.5MiB cpu_total=42.1s spawned=17 failures=0
```

A worker can also be driven by hand for debugging — it reads one framed job
from stdin and writes a framed response to stdout:

```bash
BODY='{"name":"test"}'
printf 'import-character %d\n%s' "${#BODY}" "$BODY" \
  | luajit CharacterImportService.lua --pob-root PathOfBuilding
```

### Test with docker compose

Run:

```bash
docker compose up --build
```

That starts a single container running the Go server with both PoB runtimes.

Test endpoints:

```bash
curl -X POST http://localhost:8080/poe1/import-character
curl -X POST http://localhost:8080/poe1/update-config
curl -X POST http://localhost:8080/poe2/import-character
curl -X POST http://localhost:8080/poe2/update-config
curl http://localhost:8080/healthz
```

## Runtime layout

- `main.go` - Go HTTP server: routing, worker pools, process supervision, health
- `CharacterImportService.lua` - luajit worker entrypoint (one process per request, pre-warmed)
- `pob_wrapper/CharacterImportService.lua` - worker bootstrap, stdio protocol and routing
- `pob_wrapper/Runtime/PoE1.lua` - PoE1-specific import/update behavior
- `pob_wrapper/Runtime/PoE2.lua` - PoE2-specific import/update behavior
- `pob_wrapper/Runtime/Shared.lua` - shared export and JSON helpers

## CI/CD

The GitHub Actions workflow fetches the latest PoB and PoE2 upstream refs during the build and assembles a temporary Docker build context, so the vendored runtime directories do not need to live in this repository. It publishes a single image (`pob-server:latest`) containing both runtimes.
