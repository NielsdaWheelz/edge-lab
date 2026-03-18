# edge-lab

local lab repo for the centralized edge + `frp` tunnel architecture.

this repo now has two jobs:

1. preserve the original milestone spikes
2. pin the measured phase-1 transport contract before `src/edge` is implemented in the main repo

the important shift is that `./scripts/phase1-contract.sh` is not a smoke test. it is the contract gate for the current phase-1 design.

## scope

milestone track:

1. tunnel only (`frps <-> frpc <-> app`)
2. auth (`Login` + `NewProxy` plugin checks)
3. caddy (`tls internal`) in front of the tunnel
4. route state control (`starting -> live -> removed`) via caddy admin api

phase-1 contract track:

5. generation-scoped transport hosts
6. explicit publish intent and desired/live separation
7. exact-host caddy promotion via upstream `Host` rewrite
8. revoked reconnect rejection after supersede

## current phase-1 posture

the pinned lab contract is narrower than the long-term target architecture.

- one public platform hostname
- one public http endpoint on local port `8000`
- one transport hostname per generation
- `frpc` registers transport identity, not the public hostname
- `caddy` serves generic fallback/startup responses directly in phase 1
- `codapt-edge-stub` is plugin/control logic plus caddy config projection
- synthetic probe proves the transport path before route promotion
- public body check proves the post-load cutover after caddy reload

the target architecture and the measured lab contract are documented separately in:

- [edge-proxy-tunnel-phase-1-architecture.md](./edge-proxy-tunnel-phase-1-architecture.md)
- [edge-proxy-tunnel-architecture.md](./edge-proxy-tunnel-architecture.md)

the newer phase-1 doc is authoritative for v2 work. the older doc is historical reference only.

## measured transport facts pinned here

against the current pinned `frp 0.67.0` setup, the harness asserts:

- `Login` does not carry `run_id`
- concurrent successful `Login` events reuse the same `privilege_key`
- `NewProxy` and `CloseProxy` correlate on the same `content.user.run_id`
- `Ping` is not observed during the current harness window even though plugin ops request it
- a verified but non-desired generation does not become live
- after publish request for a newer generation, the old live generation keeps serving until reconcile
- revoked reconnect attempts stop at `Login` and do not reach `NewProxy`
- final public traffic lands on the live generation transport host selected by caddy

if any of those facts drift, this repo should go red first. do not patch the main repo blindly. re-measure and update the architecture doc intentionally.

## components

- `demo-app`, `demo-app-gen2`, `demo-app-gen3`
  - node demo servers on port `8000`
  - expose `/`, `/health`, `/sse`, `/ws`, `/upload`
  - response bodies include `APP_LABEL` so cutover is externally visible
- `frps` / `frpc`
  - pinned to `0.67.0`
  - phase-1 configs live under `frps/` and `frpc/`
- `codapt-edge-stub`
  - `POST /frp-auth`
  - `POST /route/register-starting`
  - `POST /route/promote-live`
  - `POST /route/remove`
  - `POST /route/reload`
  - `POST /phase1/reset`
  - `POST /phase1/request-publish`
  - `POST /phase1/reconcile`
  - `GET /phase1/state`
- `caddy`
  - runs behind profile `caddy`
  - uses `tls internal`
  - renders wildcard fallback plus exact-host live routes from edge-managed config

## scripts

run from this repo root:

```bash
./scripts/milestone1.sh
./scripts/milestone2.sh
./scripts/milestone3.sh
./scripts/milestone4.sh
./scripts/measurements.sh
./scripts/phase1-contract.sh
```

or run the full sequence fail-fast:

```bash
./scripts/run-all.sh
```

## phase-1 contract harness

run:

```bash
./scripts/phase1-contract.sh
```

the harness deliberately does more than the old spike scripts:

- starts from a clean docker state every run
- clears stale phase-1 artifacts
- stages startup: core services first, caddy second
- captures http status codes and response bodies for edge control calls
- fails loudly with artifact dumps and docker logs
- writes a machine-readable summary to `artifacts/phase1-summary.json`

if this script passes, it should mean something. if it fails, it should explain why.

## useful manual checks

milestone 1 root request:

```bash
curl -H 'Host: preview-abc.codapt.local' http://localhost:8080/
```

public caddy route:

```bash
curl --resolve preview-abc.codapt.local:443:127.0.0.1 https://preview-abc.codapt.local/ --insecure
```

phase-1 state snapshot:

```bash
curl http://127.0.0.1:9090/phase1/state
```

## artifacts

all captured evidence lands in `artifacts/`.

key phase-1 artifacts:

- raw plugin request bodies:
  - `plugin-login.json`
  - `plugin-newproxy.json`
  - `plugin-closeproxy.json`
- auth event stream:
  - `frp-auth-events.ndjson`
- route projection:
  - `caddy-active.caddyfile`
  - `route-events.ndjson`
  - `route-state.json`
- phase-1 control and state:
  - `phase1-reset.json`
  - `phase1-request-publish-gen2.json`
  - `phase1-request-publish-gen3.json`
  - `phase1-reconcile-gen2.json`
  - `phase1-reconcile-gen3.json`
  - `phase1-probe.json`
  - `phase1-state.json`
  - `phase1-state-final.json`
  - `phase1-summary.json`
- public-path captures:
  - `phase1-no-desired-body.txt`
  - `phase1-starting-gen2.txt`
  - `phase1-live-gen2.txt`
  - `phase1-live-gen3.txt`
  - `phase1-live-gen3-post-revoke.txt`
- older measurement output:
  - `measurement-summary.json`

many `*.err` files are intentional. they capture stderr from curl-based probes so failures stop being opaque.

## helper commands

- start the standard stack: `./scripts/up.sh`
- smoke the current live route: `./scripts/smoke.sh`
- tear down and clean docker state: `./scripts/down.sh`
