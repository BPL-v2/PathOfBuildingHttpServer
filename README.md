# pob-server-v2



Headless Path of Building server wrapper for both:

- Path of Building
- Path of Building PoE2

The repository keeps the server logic here and pulls the PoB runtimes separately for local development and CI.

## Local development

### Prerequisites

- `git`
- `luajit`
- Lua modules used by the headless runtime:
  - `luaposix`
  - `luasocket`
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

PoE1:

```bash
luajit CharacterImportServer.lua --pob-root PathOfBuilding
```

PoE2:

```bash
luajit CharacterImportServer.lua --pob-root PathOfBuilding-PoE2
```

You can also use `POB_ROOT`:

```bash
POB_ROOT=PathOfBuilding luajit CharacterImportServer.lua
```

```bash
POB_ROOT=PathOfBuilding-PoE2 luajit CharacterImportServer.lua
```

Optional flags:

```bash
luajit CharacterImportServer.lua --pob-root PathOfBuilding --host 0.0.0.0 --port 8080
```

### Test both runtimes with docker compose

Run:

```bash
docker compose -f docker-compose.headless.yml up --build
```

That starts:

- a PoE1 server container
- a PoE2 server container
- an nginx reverse proxy on `localhost:8080`

Test endpoints:

```bash
curl -X POST http://localhost:8080/poe1/import-character
curl -X POST http://localhost:8080/poe1/update-config
curl -X POST http://localhost:8080/poe2/import-character
curl -X POST http://localhost:8080/poe2/update-config
```

## Runtime layout

- `CharacterImportServer.lua` - root entrypoint
- `pob_server/CharacterImportServer.lua` - shared bootstrap and routing
- `pob_server/Runtime/PoE1.lua` - PoE1-specific import/update behavior
- `pob_server/Runtime/PoE2.lua` - PoE2-specific import/update behavior
- `pob_server/Runtime/Shared.lua` - shared export and JSON helpers

## CI/CD

The GitHub Actions workflow fetches the latest PoB and PoE2 upstream refs during the build and assembles a temporary Docker build context, so the vendored runtime directories do not need to live in this repository.
