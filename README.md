# edge-lab

local spike for the 4 requested milestones:

1. tunnel only (`frps <-> frpc <-> app`)
2. auth (`Login` + `NewProxy` plugin checks)
3. caddy (`tls internal`) in front of the tunnel
4. route state control (`starting -> live -> removed`) via caddy admin API

## components

- `demo-app` (node) on port `8000` with `/`, `/health`, `/sse`, `/ws`, `/upload`
- `frps`/`frpc` pinned to `0.67.0`
- `codapt-edge-stub` with:
  - `POST /frp-auth`
  - `POST /route/register-starting`
  - `POST /route/promote-live`
  - `POST /route/remove`
  - `POST /route/reload`
- `caddy` (profile `caddy`) with `tls internal`

## milestone scripts

run from `tmp/edge-lab`:

```bash
./scripts/milestone1.sh
./scripts/milestone2.sh
./scripts/milestone3.sh
./scripts/milestone4.sh
./scripts/measurements.sh
```

or run everything fail-fast:

```bash
./scripts/run-all.sh
```

## required test commands

milestone 1 command:

```bash
curl -H 'Host: preview-abc.codapt.local' http://localhost:8080/
```

milestone 3 command:

```bash
curl --resolve preview-abc.codapt.local:443:127.0.0.1 https://preview-abc.codapt.local/ --insecure
```

## artifacts

all captured evidence lands in `artifacts/`:

- raw plugin request bodies:
  - `plugin-login.json`
  - `plugin-newproxy.json`
- auth event stream:
  - `frp-auth-events.ndjson`
- frpc admin API captures:
  - `frpc-admin-connected.json`
  - `frpc-admin-disconnected.json`
  - `frpc-admin-reload-response.json`
  - `frpc-admin-rejected.json`
- reconnect/reload summary:
  - `measurement-summary.json`

## helper commands

- start full stack (good auth + caddy base config): `./scripts/up.sh`
- full smoke against live route: `./scripts/smoke.sh`
- stop and clean: `./scripts/down.sh`
