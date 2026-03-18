# Edge Proxy Tunnel Phase 1 Architecture for v2

## Status

- This document is the authoritative target for edge tunnel work in this repo.
- It supersedes `edge-proxy-tunnel-architecture.md` for v2 implementation work.
- The older document remains a historical reference for v1 assumptions and external spike notes only.
- This document intentionally does not rely on out-of-repo lab artifacts. Any `frp` contract assumptions must be revalidated before rollout.
- This document distinguishes target repo architecture from measured lab evidence. Anything labeled “measured in `tmp/edge-lab`” is lab-backed; anything else is a target contract or an explicit future seam.

## Goal

Implement a single-node edge tunnel system for platform subdomains in this repo without pretending the rest of the hosting product already exists.

Phase 1 is deliberately narrow:

- one edge node
- one public HTTP endpoint per runtime
- platform subdomains only
- outbound `frpc` tunnels from VMs to a centralized edge
- route publication only after app readiness and tunnel verification
- explicit integration seams for later hosting/runtime work

This phase is allowed to leave the repo unfinished. It is not allowed to leave the edge slice architecturally sloppy.

## Non-Goals

- no custom domains
- no multi-node edge
- no HA story
- no arbitrary public port exposure
- no general endpoint model
- no full runtime/hosting control plane
- no runtime agent implementation
- no refactor of existing main-server or executor exposure in this phase
- no promise of zero-downtime deploys
- no attempt to preserve or port the v1 file layout described in the older doc

Custom domains are deferred on purpose. They are not “more hostnames.” They require domain ownership, verification, cert lifecycle, attach/detach policy, and publication gating. That is a separate control-plane problem.

## Current v2 Reality

The current repo does not already contain a hosting ingress architecture.

- `src/main/server` is a Bun/Effect control-plane server, not a user-app ingress plane.
- The Bun server currently mounts only `/rpc`, `/executor/rpc`, and `GET /executor/worker.js`.
- `src/main/web` is a separate TanStack/Nitro app process.
- `src/main/server/internal/db` and `src/cloud/server/internal/db` are still scaffold-level modules.
- `src/cloud/digitalocean` models generic droplet lifecycle only.
- `src/executor` is a reconnecting worker control plane over queues and heartbeats.

That means the old document cannot be “ported” into this repo. The product concepts it assumed do not exist here yet.

What is reusable from the current repo:

- `CentralHeartbeat` for liveness
- `CentralLease` for time-bounded ownership
- `CentralQueue` and PG `LISTEN`/`NOTIFY` for event fanout
- durable memoized orchestration patterns
- `PublicId` and `SecretKeyGenerator` for opaque identifiers and key derivation

What is not reusable as-is:

- the existing executor transport
- the existing executor auth model
- the old v1 status model
- the old v1 file map

## Phase 1 Target

### Traffic Path

```text
browser
  |
  | HTTPS request to preview-abc123.<platform-base-domain>
  v
Caddy on single edge node
  |
  | if host is live
  v
frps on same edge node
  |
  | outbound tunnel already established by VM
  v
frpc on VM
  |
  v
user app on local port 8000
```

For non-live hosts in the pinned lab:

```text
browser
  |
  v
Caddy on single edge node
  |
  | generic fallback or startup response rendered directly by Caddy config
  v
response
```

The lab does not prove a `codapt-edge` fallback proxy hop. It proves generic non-live responses rendered directly by `Caddy` from edge-managed config.

### Topology

Single-node means single-node.

- one public edge host
- `Caddy`, `frps`, and `codapt-edge` run on that host
- internal hops are localhost
- local Caddy storage is acceptable
- there is no HA language, no standby node, and no “easy future failover” story in this phase

### Edge Listener Bindings

Phase 1 must freeze listener exposure explicitly.

This table is target deployment posture, not a claim about docker-lab container bind addresses. The lab uses container-wide binds plus selective published ports for convenience; that is not the intended host deployment boundary.

- `Caddy` public listeners:
  - bind: `0.0.0.0:80`, `0.0.0.0:443`
  - exposure: public internet
  - purpose: end-user HTTPS ingress only
- `frps` control listener:
  - bind: public interface, e.g. `0.0.0.0:7000`
  - exposure: firewall-allowlisted VM egress CIDRs only
  - purpose: `frpc` control connections
- `frps` vhost HTTP listener:
  - bind: `127.0.0.1:8080`
  - exposure: localhost only
  - purpose: upstream for `Caddy -> frps` live traffic and edge-local synthetic probes
- `codapt-edge` HTTP listener:
  - bind: `127.0.0.1:8081`
  - exposure: localhost only
  - purpose: `frp` plugin endpoint and edge control routes only
- `Caddy` admin API:
  - bind: `127.0.0.1:2019`
  - exposure: localhost only
  - purpose: route programming and operational introspection
- `frps` dashboard, if enabled:
  - bind: `127.0.0.1:7500`
  - exposure: localhost only
  - purpose: debugging only, never public
- `frpc` admin API on each VM:
  - bind: `127.0.0.1:7400`
  - exposure: localhost only on the VM
  - purpose: local advisory signal only, never source of truth

If phase 1 cannot restrict `frps` control ingress to known VM egress CIDRs yet, that must be documented as an explicit temporary risk. It must not be silently left world-open.

### Public Contract

Phase 1 public routing contract:

- wildcard platform DNS points at the single edge node
- each runtime gets exactly one platform hostname
- each runtime exposes exactly one public HTTP endpoint
- that public endpoint is fixed to local port `8000`

Anything broader is deferred.

Phase 1 also has a transport contract:

- each generation gets one edge-internal transport hostname
- `frpc` registers the generation transport hostname, not the public platform hostname
- the transport hostname is an edge routing identity only; it is never user-visible

## Core Design Decisions

### 1. Hostnames belong to logical runtimes, not VMs

The routed identity is a stable logical runtime.

The VM is where one deployment generation happens to run.

A hostname must never mean “whatever VM currently exists.” That recreates the v1 coupling that caused ingress instability.

### 2. Live traffic is published to immutable generations

Each runtime has a monotonic generation sequence.

The edge publishes one specific generation as live. It does not publish a VM and it does not publish a vague runtime blob.

This is the minimum safe model for:

- safe redeploy
- stale-tunnel rejection
- future draining
- future rollback

### 3. Public host and transport host are separate

The public platform hostname and the `frp` registration hostname are different objects.

For phase 1:

- the runtime owns one stable public hostname
- each generation owns one immutable edge-internal transport hostname
- `frpc` registers the transport hostname only
- `Caddy` selects the live generation by rewriting the upstream `Host` header to that generation’s transport hostname

This is not optional polish. It is the minimum safe model for overlapping verified generations.

If `frpc` registers the public hostname directly, old and new generations fight over the same `frp` host identity and clean cutover becomes fragile or impossible.

### 4. Desired state and observed state are separate

Do not collapse readiness, connectivity, certs, and publication into one enum.

This phase has no custom domains, so cert readiness is mostly out of scope. Even so, desired and observed state must remain separate:

- desired state says which generation should become live
- observed state says which tunnel sessions are actually connected and verified
- publication state says which generation is actually receiving traffic

### 5. Publication intent is explicit

Observed tunnel readiness may satisfy publication intent. It must never create publication intent.

The caller must explicitly request publication of one generation. That request sets `desired_generation_id`.

Edge may only ever promote the current `desired_generation_id` after the required gates pass. A verified tunnel for any non-desired generation is recorded for observation only. It must never become live automatically.

If `desired_generation_id != live_generation_id`, public traffic continues to flow to the current live generation until the desired generation passes the promotion gates.

### 6. Edge owns observed tunnel state and route publication

The edge is the source of truth for:

- tunnel lease validation
- observed tunnel sessions
- Caddy route programming
- current live generation pointer
- the persisted record of which desired generation has actually been published

The future runtime/hosting layer will own higher-level deploy intent. It is not implemented in this phase.

`Caddy` and `frps` are data-plane components. They are projections of persisted edge state, not the source of desired ownership.

### 7. `codapt-edge` is not the steady-state live proxy

Steady-state live traffic should go:

```text
Caddy -> frps -> frpc -> app
```

`codapt-edge` exists for:

- `frp` plugin auth
- route reconciliation
- Caddy API integration
- projection of generic fallback/startup responses into Caddy config

It should not sit in front of every live request.

## Module Boundaries

Phase 1 adds a new module:

- `src/edge`

`src/edge` owns:

- edge DB schema and migrations
- edge Effect services
- edge server entrypoints
- `frp` plugin HTTP endpoints
- Caddy API client
- route reconciliation
- Caddy route and fallback projection

Existing modules stay narrow:

- `src/cloud/digitalocean` remains generic VM lifecycle
- `src/executor` remains generic remote execution/bootstrap glue
- `src/main/server` remains the existing control-plane server

This phase does not merge edge into executor. Shared use of long-lived connections is not a reason to collapse modules.

### Ownership Boundary

The edge persists the minimum route-control records it needs in phase 1 because no hosting/runtime module exists yet.

That is a bootstrap concession, not a long-term ownership claim.

Long-term ownership split:

- future hosting/runtime layer owns product runtime identity, generation intent, and app lifecycle
- edge owns tunnel admission, observed session state, and traffic publication

Phase-1 edge APIs may temporarily create runtime/generation records directly. That does not make edge the permanent product owner of those concepts.

## Minimal Substrate Floor

This is the smallest substrate that makes edge tunnels implementable cleanly.

It is not the full hosting product. It is the minimum safe floor.

These tables are edge-local route-control records for phase 1. They are the minimum persisted substrate the edge needs in an unfinished repo. They do not imply that edge is the permanent owner of product runtime semantics.

### `edge_runtimes`

Stable public identity.

Suggested columns:

- `id uuid primary key default uuidv7()`
- `created_at timestamptz not null default now()`
- `platform_hostname text not null unique`

Meaning:

- one row per logical routable runtime
- phase 1 has exactly one platform hostname per runtime

### `edge_runtime_generations`

Immutable deployment candidates.

Suggested columns:

- `id uuid primary key default uuidv7()`
- `created_at timestamptz not null default now()`
- `edge_runtime_id uuid not null`
- `generation integer not null`
- `vm_id uuid not null`
- `transport_hostname text not null unique`
- `app_ready_at timestamptz null`
- `superseded_at timestamptz null`

Constraints:

- unique `(edge_runtime_id, generation)`

Meaning:

- one row per immutable generation of a runtime
- tied to one VM in phase 1
- `transport_hostname` is the immutable edge-internal host that `frpc` registers for this generation
- in phase 1, `vm_id` should refer to the concrete provider VM row, e.g. `cloud_digitalocean_vms.id`
- `app_ready_at` is written only after the caller proves the app is serving on port `8000`
- `tmp/edge-lab` does not currently model `app_ready_at`; the demo app is treated as ready by construction, and the lab only proves tunnel verification plus transport/public-path cutover

### `edge_tunnel_leases`

Short-lived tunnel credentials.

Suggested columns:

- `id uuid primary key default uuidv7()`
- `created_at timestamptz not null default now()`
- `edge_runtime_generation_id uuid not null`
- `credential_hash text not null unique`
- `expires_at timestamptz not null`
- `revoked_at timestamptz null`

Meaning:

- auth credential for one generation
- random high-entropy token
- hash stored at rest
- revocable and expiring

Do not use `PublicId` as auth. `PublicId` is for opaque identifiers, not credential semantics.

### `edge_tunnel_sessions`

Observed connection facts from the edge.

Suggested columns:

- `id uuid primary key default uuidv7()`
- `created_at timestamptz not null default now()`
- `edge_runtime_generation_id uuid not null`
- `edge_tunnel_lease_id uuid not null`
- `session_key text not null`
- `proxy_name text not null`
- `connected_at timestamptz null`
- `verified_at timestamptz null`
- `last_seen_at timestamptz not null`
- `disconnected_at timestamptz null`
- `reject_reason text null`

Suggested indexes:

- index `(edge_runtime_generation_id, session_key)`

Meaning:

- append-only-ish record of one observed tunnel session
- `session_key` is the measured `frp` `run_id` used for phase-1 correlation across `NewProxy` and `CloseProxy`
- status is derived from facts, not stored as a catch-all enum
- the lab proves `run_id` correlation across session birth and close, not global uniqueness across time; repo phase 1 should prefer append-only raw auth events plus derived session rows over a naked unique constraint on `session_key`

### `edge_route_publications`

Live traffic pointer.

Suggested columns:

- `id uuid primary key default uuidv7()`
- `created_at timestamptz not null default now()`
- `edge_runtime_id uuid not null unique`
- `desired_generation_id uuid null`
- `desired_at timestamptz null`
- `live_generation_id uuid null`
- `published_at timestamptz null`
- `draining_generation_id uuid null`
- `draining_at timestamptz null`

Meaning:

- per-runtime publication state
- desired and live are separate on purpose
- draining is explicit, even if phase 1 only uses it lightly

## Invariants

These are the core correctness rules.

1. A hostname binds to a runtime, never directly to a VM.
2. A generation belongs to exactly one runtime.
3. A tunnel lease belongs to exactly one generation.
4. A tunnel session belongs to exactly one generation and exactly one lease.
5. A generation may become live only if:
   - the generation exists
   - `app_ready_at` is set
   - there is an active, verified tunnel session for that generation
   - the validating lease is not expired or revoked
6. A superseded generation must not be able to reclaim the hostname.
7. Observed tunnel state must not silently overwrite desired deploy state.
8. Publication must be derivable from normalized facts, not a single mega-status enum.
9. Phase 1 has one public endpoint only: HTTP on local port `8000`.
10. Custom domains do not exist in this phase.
11. A generation may become live only if it is the current `desired_generation_id`.
12. `frpc` must never register the public platform hostname directly. It must register the generation’s `transport_hostname`.
13. Publishing a newer generation must revoke the previous generation’s lease immediately to block future reconnects.
14. Prompt shutdown of the previous generation is operational cleanup, not public-route safety. Once `Caddy` points at a different `transport_hostname`, the old generation can remain connected harmlessly until drained.
15. Phase 1 does not assume `Ping`-based liveness. The proven birth/death signals are `NewProxy` and `CloseProxy`, and publication safety is additionally gated by a successful synthetic probe.
16. `Caddy` and `frps` configuration are projections of persisted edge state, not the source of desired route ownership.

In invariant 5, `app_ready_at` is target repo phase-1 state, not current lab evidence. The lab presently proves only tunnel verification, transport-path probe success, and public-route cutover.

## `frp` Contract for Phase 1

Phase 1 should use `frp` plugin hooks not just for auth, but also for session observation.

Only measured hooks belong in the correctness model.

Required measured hooks:

- `Login`
- `NewProxy`
- `CloseProxy`

Optional only after explicit re-measurement and config pinning:

- `Ping`

Measured in `tmp/edge-lab` against `frp 0.67.0`:

- `Login` carried `privilege_key` but no `run_id`
- concurrent `Login` events reused the same `privilege_key`, so `privilege_key` is not a safe session key
- `NewProxy` and `CloseProxy` carried `content.user.run_id`
- `Ping` was not observed within the phase-1 harness window even with plugin ops configured to request it, so it is not part of the proven session contract yet
- after lease revocation, reconnect attempts were rejected at `Login` and did not reach `NewProxy` within the harness window

If a future `frp` version or config changes any of those facts, rerun the lab and update this section before rollout.

`tmp/edge-lab/scripts/phase1-contract.sh` is the pinned evidence gate for those facts. It must start from a clean lab state, fail loudly with captured response bodies and logs, and assert at least:

- `Login` still omits `run_id`
- concurrent allowed `Login` events still reuse `privilege_key` in the pinned `frp 0.67.0` lab
- `NewProxy` and `CloseProxy` still correlate on the same `run_id`
- `Ping` is still absent from the proven phase-1 liveness contract unless this document is updated
- desired/live separation still holds during publish
- revoked reconnects still stop at `Login` and do not reach `NewProxy`
- the final public route still rewrites to the live generation’s `transport_hostname`

If that harness drifts red, do not “fix forward” in `src/edge`. Re-measure the transport contract first and then update this document intentionally.

### Identity, Carried Metadata, and Issued Transport Config

Phase 1 metadata carried by `frpc` should be:

- authoritative credential:
  - `lease_token`
- non-secret assertion for correlation and diagnostics:
  - `generation_public_id`

`lease_token` is the actual credential.

`generation_public_id` is not auth. It must be opaque outside the DB boundary and should be implemented with `PublicId` or another opaque derived identifier.

Phase 1 transport config issued out of band by edge should be:

- `transport_hostname`
- pinned `proxy_name`

`transport_hostname` and `proxy_name` are not carried auth metadata. They are immutable generation transport config that `frpc` uses when it opens `NewProxy`, and the edge cross-checks the presented subdomain/derived host plus `proxy_name` against persisted state.

Any metadata other than `lease_token` is cross-checked against persisted state. It is never trusted on its own.

### Proxy Naming Contract

Phase 1 has exactly one public endpoint, so there should be exactly one allowed proxy naming pattern per generation.

Recommended convention:

- `g_<generation_public_id>__app`

Properties:

- deterministic
- non-secret
- unique per generation
- endpoint-specific

The exact grammar and maximum safe length must be pinned against the measured `frp` version before rollout. If the chosen `generation_public_id` representation is too long, the edge must derive a shorter non-secret deterministic label from it and freeze that rule here before rollout.

### Transport Host Contract

Each generation gets one immutable edge-internal transport hostname.

Properties:

- unique per generation
- DNS-safe
- not user-visible
- not equal to the runtime’s public `platform_hostname`

Recommended shape:

- `g-<generation_dns_label>-<runtime_slug>.<platform_base_domain>`

If the chosen `generation_public_id` is not DNS-safe or is too long for a host label, the edge must derive a shorter deterministic DNS-safe label and persist the resulting `transport_hostname` on the generation row.

`Caddy` selects the live generation by rewriting the upstream `Host` header to that generation’s `transport_hostname`.

### Session Correlation Contract

`edge_tunnel_sessions.session_key` should be the measured `frp` `run_id` used for phase-1 correlation.

Phase 1 measured contract:

- `Login` is an auth event, not the mutable session row
- `NewProxy` births the session row keyed by `content.user.run_id`
- `CloseProxy` updates that same session row by the same `run_id`
- `privilege_key` must not be used as a session key

If `Ping` later becomes observable with the same `run_id`, it may refresh session freshness. Phase 1 does not depend on that.

If future measurement or upstream guarantees do not establish stronger uniqueness, keep raw auth events append-only and derive session rows from them. Do not promote `run_id` into a naked global uniqueness assumption by habit.

### Validation rules

On `Login`:

- `generation_public_id` resolves to one generation
- lease token hashes to an active lease for that generation
- lease is not expired
- lease is not revoked

On `NewProxy`:

- all `Login` checks still hold
- requested subdomain and derived host match the generation’s `transport_hostname`
- requested proxy name matches the pinned phase-1 convention
- requested exposure is the phase-1 public endpoint only

On `CloseProxy`:

- session correlation is by the measured `run_id`
- lease revocation must not block observation of the close event for an already-established session

### Observation rules

On allow:

- do not create a mutable session row on `Login`
- create or update an `edge_tunnel_sessions` row on `NewProxy`
- correlation is by `run_id`, not by guesswork
- set `connected_at` and `verified_at` on first successful `NewProxy`
- refresh `last_seen_at` on `NewProxy`
- set `disconnected_at` on `CloseProxy`
- if `Ping` is later measured and pinned, use it only to refresh `last_seen_at`

On reject:

- record `reject_reason`
- do not publish the route
- lease revocation should block future `Login`; in the pinned `frp 0.67.0` harness, rejected reconnects stop at `Login` and do not reach `NewProxy`

Do not rely on the `frpc` admin API alone as the source of truth for route readiness.

### Session Liveness Contract

Phase 1 proven contract:

- session birth is `NewProxy`
- session death is `CloseProxy` when observed
- promotion safety is additionally gated by a successful synthetic probe through the desired generation’s `transport_hostname`

Because `Ping` is not yet part of the proven contract, `last_seen_at` is not a strong freshness signal in phase 1. If later heartbeat config makes `Ping` observable and stable, phase 1 can tighten this with a named keep-alive policy in `src/keep-alive-policies.ts`.

## Publication Model

### Publication states are derived, not monolithic

For a runtime:

- if there is no `live_generation_id`, the runtime is not live
- if there is a `desired_generation_id` but no `live_generation_id`, it is pending publication
- if `live_generation_id == desired_generation_id`, the desired generation is live
- if `live_generation_id != desired_generation_id`, the old live generation keeps serving public traffic until the desired generation is promoted
- if `draining_generation_id` is set, that generation is being removed from service

For a generation:

- in target repo phase 1, app-ready is `app_ready_at is not null`
- in the current lab, app readiness is assumed by construction and is not an independently modeled gate
- tunnel-verified means at least one active session satisfies the phase-1 session liveness contract
- live means publication points at that generation

### Publication algorithm

For one runtime:

1. generation is created
2. caller explicitly requests publication of that generation
3. edge writes `desired_generation_id` and `desired_at`
4. caller marks generation app-ready
   - current `tmp/edge-lab` does not model this state and assumes the demo app is already serving
5. caller mints a tunnel lease and receives the desired generation’s transport config
6. VM starts `frpc` against the generation’s `transport_hostname` and pinned `proxy_name`
7. edge observes a verified `NewProxy` session for the desired generation
8. edge runs a bounded edge-local synthetic probe through the full live path candidate:
   - target: local `frps` vhost HTTP listener
   - host header: desired generation `transport_hostname`
   - expected result: successful response from the app on port `8000`
9. on successful probe, edge reconciler programs the exact-host live route in `Caddy` and rewrites the upstream `Host` header to the desired generation `transport_hostname`
10. after successful route programming, edge writes `live_generation_id = desired_generation_id` and `published_at`
11. any prior live generation:
   - moves to `draining_generation_id`
   - has its lease revoked immediately to block future reconnects
   - is stopped or drained explicitly out of band; prompt disconnect is cleanup, not public-route safety

A generation must not be published before step 8.

Publication is a durable reconciliation, not a single SQL transaction. `Caddy` configuration is an external projection. The reconciler must be idempotent across retry and crash-replay.

Verified but non-desired generations are allowed to exist for warm-up and observation. They are never auto-published.

Measured in `tmp/edge-lab`, public cutover lagged briefly after reconcile while `Caddy` reloaded the new config. That means route promotion is externally observable only after the data-plane reload commits.

Current lab proof is intentionally split into two observations:

- pre-load transport proof: synthetic probe to local `frps` with `Host = transport_hostname`
- post-load public proof: eventual body check through the public `Caddy` route

That is good enough for phase-1 contract measurement. The long-term-safe production answer is to acknowledge cutover only after both stages pass in the real reconciler.

### Caddy behavior

For the phase-1 wildcard base domain:

- wildcard fallback route is rendered directly by `Caddy` from edge-managed config
- no runtime row: `Caddy` returns a generic `404`
- runtime exists but no live generation: `Caddy` returns a generic startup or unavailable response
- runtime has live generation: exact-host route overrides the wildcard fallback and goes directly to `frps`, with upstream `Host` rewritten to the live generation `transport_hostname`
- if `desired_generation_id != live_generation_id`, the exact-host route continues to point at the current live generation until promotion completes

This avoids publishing live traffic before the tunnel is actually ready.

If a future phase needs runtime-specific startup pages, that should be added explicitly as a new feature. It is not part of the phase-1 measured contract.

## Temporary Integration Contract

The future runtime/hosting layer is not implemented in this phase.

That does not mean edge should guess its future integration shape. The seam should be explicit now.

The minimum calls edge needs from an external orchestrator are:

- `createRuntime(platformHostname) -> runtimeId`
- `beginGeneration(runtimeId, vmId) -> { generationId, generationPublicId, transportHostname, proxyName }`
- `markGenerationAppReady(generationId)`
- `mintTunnelLease(generationId, ttl) -> { leaseToken, expiresAt }`
- `requestPublish(generationId)`
- `requestDrain(generationId)`
- `requestStop(generationId)`

Phase 1 may satisfy these calls in ugly ways at first:

- manual scripts
- direct service invocations
- executor-driven bootstrap code

That is acceptable.

What is not acceptable:

- encoding these decisions implicitly in random shell scripts with no persisted state model
- making `frps` or Caddy the source of truth for desired route ownership

The existence of temporary edge-side `createRuntime` and `beginGeneration` calls in phase 1 does not make edge the permanent owner of those concepts. It is bootstrap convenience until phase 2 supplies the real caller.

## Temporary Phase 1 Posture for VM Integration

Because the future runtime layer does not exist yet, phase 1 may use executor as bootstrap glue only.

That means executor may be used to:

- install `frpc` on the VM
- write `frpc` config
- restart or reload `frpc`
- stop the superseded generation’s `frpc` process after cutover
- ask the VM to start the app on port `8000`

That does not make executor the long-term runtime agent.

Executor remains:

- a transport
- a bootstrap path
- a break-glass control tool

It is not the target hosting architecture.

## Single-Node Operational Topology

This phase assumes:

- one edge node
- one wildcard platform cert
- one wildcard DNS target
- local Caddy storage

That means:

- no `edge_node_id` data model yet
- no shared Caddy storage
- no owner-aware multi-node routing
- no DNS-based traffic balancing

Do not write fake HA scaffolding into phase 1. Add it later when it is real.

## Known Debt Explicitly Left Out of Scope

Phase 1 does not fix everything already present in the repo.

Known debt left standing:

- the existing main-server and executor exposure model
- the lack of a dedicated runtime agent
- the absence of a full hosting/runtime module
- the absence of custom-domain control-plane logic
- the absence of a proper user-facing deploy API

This phase should not make those debts worse.

## Implementation Shape in This Repo

The expected shape is a new `src/edge` module with its own entrypoints.

Suggested files:

- `src/edge/server/routes.ts`
- `src/edge/server/setup.ts`
- `src/edge/server/maintenance.ts`
- `src/edge/server/bin/serve.ts`
- `src/edge/server/bin/setup.ts`
- `src/edge/server/bin/maintenance.ts`
- `src/edge/server/internal/db/schema.ts`
- `src/edge/server/internal/db/service.ts`
- `src/edge/server/internal/db/migrator.ts`
- `src/edge/server/internal/db/migrations/0001_edge_init.ts`
- `src/edge/server/internal/edge-service.ts`
- `src/edge/server/internal/frp-plugin-route.ts`
- `src/edge/server/internal/caddy-client.ts`
- `src/edge/server/internal/caddy-config-renderer.ts`
- `src/edge/server/internal/publication-reconciler.ts`

This keeps edge self-contained and avoids pretending it is just another executor subfeature.

Edge DB functionality should live entirely inside `src/edge` with its own migrations, following the repo rules for:

- `uuidv7` primary keys
- `created_at timestamptz not null default now()`
- `DbNow` for timestamp comparisons
- explicit select-then-insert/update instead of `ON CONFLICT`
- durable orchestration for DB-plus-external-side-effect flows

## Deferred Work

Explicitly deferred after phase 1:

- custom domains
- per-domain cert orchestration
- arbitrary endpoint exposure
- runtime/hosting module
- runtime agent
- public/private network split for existing executor surfaces
- multi-node edge
- HA and owner-aware routing
- zero-downtime deploy claims

## Later Phases

This section documents the next phases at the architectural level only.

They are not part of phase 1 implementation.

### Phase 2: Runtime and Hosting Orchestration

Phase 2 is the caller of the phase-1 edge system.

Phase 1 builds the edge machinery:

- tunnel auth
- tunnel observation
- route publication
- generic fallback projection into `Caddy`

Phase 2 builds the thing that decides when and how that machinery should be used.

Phase 2 owns:

- logical runtime creation
- generation creation
- VM selection and association
- app startup lifecycle
- app readiness proof
- calls into edge to mint leases, request publication, request drain, and request stop
- product-facing runtime and deploy semantics

Phase 2 does not own:

- `Caddy`
- `frps`
- tunnel admission
- route publication internals

The phase-1 temporary integration contract is the seam that phase 2 will later implement for real.

The expected end state after phase 2:

- the temporary executor/manual/bootstrap glue is reduced or removed
- runtime creation and generation progression are first-class product operations
- edge no longer has to infer deploy intent from ad hoc scripts

### Phase 3: Custom Domains

Phase 3 adds the custom-domain control plane.

This is separate from phase 1 on purpose. Custom domains are not “extra hostnames.” They require product and operational state beyond tunneling.

Phase 3 owns:

- a global hostname registry spanning platform and custom hostnames
- custom-domain attachment to logical runtimes
- conflict prevention
- DNS-target verification
- custom-domain cert readiness
- route publication gating on:
  - runtime generation intent
  - app readiness
  - verified tunnel
  - domain attachment
  - cert readiness
- safe detach and reassignment semantics

Phase 3 does not change the phase-1 traffic core:

```text
Caddy -> frps -> frpc -> app
```

It adds domain ownership and cert-serving control on top of that traffic path.

The expected end state after phase 3:

- platform subdomains and custom domains are both first-class routed identities
- the edge can safely refuse publication for a domain that is attached but not verified or not cert-ready

### Phase 4: Boundary and Security Cleanup

Phase 4 hardens the unfinished-repo shortcuts that phase 1 intentionally leaves standing.

Phase 4 owns:

- separation of public app ingress from worker/control-plane traffic
- stronger auth posture for workers, VM bootstrap, and tunnel credentials
- tighter network boundaries and exposure rules
- cleanup of mixed-surface assumptions in the current main server
- operational hardening around secrets, logging, and edge failure visibility

Phase 4 is where the system stops tolerating “unfinished repo” boundary compromises.

It may include:

- moving executor/control endpoints behind private network policy or separate listeners
- replacing weak bootstrap assumptions with stronger credential issuance and rotation
- tightening which components are publicly reachable at all

The expected end state after phase 4:

- public ingress is only for user app traffic and intentional product surfaces
- control traffic is clearly segregated
- tunnel and worker auth no longer rely on unfinished-repo trust shortcuts

HA is still not part of phases 2 through 4. Multi-node edge and owner-aware routing remain later work after these phases.

## Why This Is the Right Phase 1

This is the minimum design that is both:

- small enough to implement as the edge slice in an unfinished repo
- structured enough not to poison future hosting integration

Anything smaller becomes ad hoc infrastructure wiring.

Anything larger stops being “edge tunnels” and turns into “finish the hosting product first.”
