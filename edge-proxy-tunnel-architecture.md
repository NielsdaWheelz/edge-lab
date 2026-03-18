# Edge Proxy & Tunnel Architecture

> Spec for replacing the per-HelperServer nginx proxy with a centralized edge proxy + frp tunnel system.

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current Architecture](#2-current-architecture)
3. [Target Architecture](#3-target-architecture)
4. [Key Concepts (Glossary)](#4-key-concepts-glossary)
5. [Technology Choices](#5-technology-choices)
6. [Edge Proxy Server Setup](#6-edge-proxy-server-setup)
7. [Codebase Changes](#7-codebase-changes)
8. [Manual Validation (Proof of Concept)](#8-manual-validation-proof-of-concept)
9. [Migration & Cutover Plan](#9-migration--cutover-plan)
10. [Failure Modes & Mitigations](#10-failure-modes--mitigations)
11. [Security](#11-security)
12. [Observability](#12-observability)
13. [Open Questions for CTO](#13-open-questions-for-cto)
14. [File Reference](#14-file-reference)
15. [Appendix: Technology Evaluation](#15-appendix-technology-evaluation)

---

## 1. Problem Statement

### Evidence quality

- **repo-proven:** helperserver-local proxy setup/teardown, vm de-association on stop, custom-domain dns checks against helperserver ip, hardcoded endpoint exposure, and runtime startup ordering.
- **inferred from external scripts / infra:** exact proxy implementation on helperservers, exact wildcard dns topology, and exact cert tooling on helperservers. the shell entrypoints are referenced in repo, but their bodies live outside it at `/opt/codapt-server-utils/bin/`.

### What's broken today

1. **Proxy is coupled to the VM host.** Repo-proven fact: public proxy rules are created and deleted on the current HelperServer during `startVm()` / `stopVm()`. Repo-proven fact: `stopVm()` clears `helperServerId`, and `startVm()` may choose a different HelperServer. That means public ingress depends on VM placement. Exact DNS behavior is inferred, but the architectural coupling is not.

2. **Custom domains break on VM migration.** Users point their domain to the HelperServer's IP via a manual A record. When the VM restarts on a different HelperServer, the IP changes and the custom domain stops working.

3. **Certificates are distributed and externally managed.** The repo delegates HelperServer HTTPS setup to external shell scripts. That means cert lifecycle for user deployments is not versioned or reviewable through this repo and is not centralized at the product edge.

4. **Requests can hit a route before the app is actually ready.** Repo-proven fact: HelperServer proxy rules are created in `startVm()` before code transfer, setup, readiness checks, and browser validation happen later in `launchUserProjectRuntime()`. That creates a real startup window where the route exists but the app may not be ready.

5. **Adding a custom domain requires a full VM restart.** The `addCustomDomainToDeploymentProcedure` calls `restartUserProjectRuntime()`, which stops the VM, then starts it from scratch. This causes downtime for the user's running app.

6. **Public endpoint exposure is hardcoded and underspecified.** The current traffic plane exposes 8000, 9000, and 9001 by convention. That is not an endpoint model; it is legacy behavior baked into scripts.

7. **Proxy scripts are outside this repo.** `setup-https-proxy.sh`, `delete-https-proxy.sh`, etc. live at `/opt/codapt-server-utils/bin/` on the HelperServer image. They can't be versioned, reviewed, or tested through normal development workflows.

8. **No centralized ingress.** Each HelperServer is its own networking island. No single place to apply rate limiting, DDoS protection, observability, or access control to user-facing traffic.

---

## 2. Current Architecture

### Traffic flow

```
user's browser
    │
    │  HTTPS request to preview-abc123.codapt.ai
    ▼
DNS / public routing (exact topology partly inferred)
    │
    ▼
HelperServer (port 443)
    │  host-local reverse proxy terminates TLS
    │  reads Host header, finds matching proxy rule
    ▼
VM bridge network (port 8000)
    │
    ▼
user's app receives the request
```

### How proxy rules are managed

**On VM start** (`vm-management.ts` → `startVm`, lines 501-527):
```bash
# runs on the HelperServer's executor
/opt/codapt-server-utils/bin/setup-https-proxy.sh ${vmName} 8000 ${subdomain}
/opt/codapt-server-utils/bin/setup-https-proxy.sh ${vmName} 9000 ${subdomain}--9000
/opt/codapt-server-utils/bin/setup-https-proxy.sh ${vmName} 9001 ${subdomain}--9001
```

**For custom domains** (`vm-management.ts` → `startVm`, lines 515-527):
```bash
/opt/codapt-server-utils/bin/setup-https-proxy-custom-domain.sh ${vmName} 8000 ${customDomain}
```

**On VM stop** (`vm-management.ts` → `stopVm`, lines 632-674):
```bash
/opt/codapt-server-utils/bin/delete-https-proxy.sh ${subdomain}
/opt/codapt-server-utils/bin/delete-https-proxy.sh ${subdomain}--9000 || true
/opt/codapt-server-utils/bin/delete-https-proxy.sh ${subdomain}--9001 || true
/opt/codapt-server-utils/bin/delete-https-proxy-custom-domain.sh ${customDomain}
```

### Entity relationships

```
HelperServer
├── ExecutorInstance (for managing the host: create/start/stop VMs, configure proxy)
├── VM-abc
│   ├── ExecutorInstance (for running commands inside this VM)
│   └── backs UserProjectRuntime (has subdomain + optional customDomain)
├── VM-def
│   ├── ExecutorInstance
│   └── backs UserProjectRuntime
└── nginx/caddy (proxy rules for all VMs on this host)
```

### DNS

- Public subdomains are realized through HelperServer-local proxy configuration.
- Custom domains are validated against the current HelperServer IP.
- Exact wildcard DNS topology is not fully visible in this repo and should be treated as inferred infrastructure context, not a proved code-level fact.

### Custom domain flow (current)

1. User calls `addCustomDomainToDeploymentProcedure` with their domain
2. Procedure validates: deployment exists, is persistent, no existing custom domain, domain not taken
3. Updates `UserProjectRuntime.customDomain` in DB
4. If deployment is running, calls `restartUserProjectRuntime()`:
   - `stopVm()` → tears down proxy rules, stops VM, de-associates from HelperServer
   - `startVm()` → picks new (or same) HelperServer, boots VM, runs `setup-https-proxy-custom-domain.sh`
5. User must point their DNS to the HelperServer's IP
6. User can verify via `checkDnsConfigProcedure` which compares their domain's resolved IP to the HelperServer's domain IP

**File:** `packages/api/src/procedures/client-api-v1/deployment/add-custom-domain-to-deployment.ts`
**File:** `packages/api/src/procedures/client-api-v1/deployment/check-dns-config.ts`

---

## 3. Target Architecture

### Traffic flow

```
user's browser
    │
    │  HTTPS request to preview-abc123.codapt.ai
    ▼
DNS wildcard: *.codapt.ai → canonical edge target (stable contract)
    │
    ▼
Edge Proxy Server
    │
    ├── Caddy terminates TLS
    │   - wildcard cert for *.codapt.ai (Let's Encrypt via DNS-01 challenge)
    │   - proactively-managed certs for custom domains
    │   - exact-host routes are registered dynamically
    │
    ├── live route => reverse proxy directly to frps on localhost:8080
    │
    ├── starting/draining route => startup or unavailable handler
    │   served by codapt-edge on localhost:8081
    │
    └── frps forwards through tunnel to frpc on the VM
            │
            ▼
        user's app on port 8000
```

### Architecture diagram

```
                    ┌──────────────────────────────────┐
                    │        Edge Proxy Server          │
                    │                                    │
                    │  ┌──────────────────────────────┐ │
user's browser ────→│  │ Caddy (ports 80/443)         │ │
                    │  │ - TLS termination            │ │
                    │  │ - wildcard cert (*.codapt.ai)│ │
                    │  │ - managed custom-domain certs│ │
                    │  │ - dynamic per-host routes    │ │
                    │  └───────┬───────────┬──────────┘ │
                    │          │ live      │ startup    │
                    │  ┌───────▼────────┐  │            │
                    │  │ frps                          │ │
                    │  │ - tunnel fabric only          │ │
                    │  │ - plugin auth via codapt-edge │ │
                    │  │ - control port 7000           │ │
                    │  └─────────────┬────────────────┘ │
                    │                │                  │
                    │  ┌─────────────▼────────────────┐ │
                    │  │ codapt-edge (port 8081)      │ │
                    │  │ - frp plugin auth            │ │
                    │  │ - caddy api integration      │ │
                    │  │ - route/state cache          │ │
                    │  │ - startup/unavailable pages  │ │
                    │  └──────────────────────────────┘ │
                    └────────────────┼──────────────────┘
                                     │
                    tunnel connections (outbound from VMs, TLS-encrypted)
                    ┌────────────────┼────────────────────┐
                    ↓                ↓                    ↓
               ┌─────────┐    ┌─────────┐          ┌─────────┐
               │  VM on   │    │  VM on   │          │  VM on   │
               │ Helper A │    │ Helper B │          │ Helper C │
               │  (frpc)  │    │  (frpc)  │          │  (frpc)  │
               └─────────┘    └─────────┘          └─────────┘
```

### What changes

| Aspect | Before | After |
|--------|--------|-------|
| DNS `*.codapt.ai` | → HelperServer IP | → Edge Proxy IP (stable) |
| TLS termination | per-HelperServer nginx | centralized Caddy on edge proxy |
| Route authority | HelperServer-local scripts | Codapt-owned desired state + codapt-edge enforcement |
| Tunnel auth | implicit host trust | per-runtime/per-launch credential validated on day one |
| Proxy rules | shell scripts on HelperServer | tunnel registration plus edge route cache |
| Custom domain certs | external HelperServer scripts | proactive Caddy API registration + cert provisioning |
| VM migration | breaks subdomain | subdomain stays working (tunnel reconnects) |
| Custom domain on restart | breaks (IP changes) | stays working (canonical edge target is stable) |
| Adding custom domain | VM restart required | route update + cert pre-provision + frpc reload |
| Public endpoints | hardcoded 8000/9000/9001 | explicit route/endpoint model, default one public app endpoint |
| 502 during deploy | yes (proxy rule exists before app ready) | avoided by route promotion only after app + tunnel + cert readiness |
| Proxy cleanup on stop | explicit script to delete rules | automatic (tunnel dies with VM) |

### Entity relationships (new)

```
Edge Proxy Server
├── Caddy (TLS termination + certificate management)
├── codapt-edge (frp auth, route compiler, Caddy API client, startup/unavailable handler)
└── frps (tunnel fabric; auth delegated to codapt-edge plugin)

HelperServer
├── ExecutorInstance (for host management only — no more proxy config)
├── VM-abc
│   ├── ExecutorInstance (for running commands inside VM)
│   ├── frpc (tunnel client, connects outbound to edge proxy)
│   └── backs UserProjectRuntime
```

HelperServers no longer run any user-facing proxy infrastructure.

---

## 4. Key Concepts (Glossary)

**SSL/TLS:** Encryption protocol for HTTPS. "SSL" is the old name; everything modern uses TLS. When a browser connects to `https://something.com`, the server and browser do a handshake to establish encryption keys. The server needs a *certificate* to prove it's legitimate.

**SSL termination:** The point where encrypted HTTPS traffic gets decrypted into plain HTTP. Everything downstream of the termination point sees unencrypted traffic. Standard practice — your internal network is trusted.

**Let's Encrypt:** A free, automated certificate authority. You prove you control a domain, and it gives you a certificate. Two challenge types:
- **HTTP-01:** Let's Encrypt makes an HTTP request to your domain to verify control. Works for individual domains.
- **DNS-01:** You create a DNS TXT record to verify control. Required for wildcard certs (`*.codapt.ai`).

**Wildcard certificate:** A single cert that covers all subdomains of a domain. `*.codapt.ai` covers `preview-abc.codapt.ai`, `my-app.codapt.ai`, etc. Obtained via DNS-01 challenge.

**Reverse proxy:** A server that receives requests on behalf of backend services and forwards them. nginx is the most common example. It reads the `Host` header to decide which backend to route to.

**Tunnel:** A persistent connection from a private machine (inside a network, behind a firewall) to a public server. Traffic flows through this connection. The key insight: the private machine connects *outbound* to the public server, so it doesn't need open ports or a public IP.

**frp (Fast Reverse Proxy):** Open-source tunnel software. Has a server component (frps) and a client component (frpc). frpc runs on the private machine, connects to frps, and registers a subdomain. frps routes incoming HTTP requests by Host header to the correct tunnel.

**Edge proxy:** A dedicated server (or cluster) at the network edge that handles all incoming user traffic. It terminates TLS, routes requests, and forwards them to backend services (in our case, through frp tunnels to VMs).

**codapt-edge:** A small edge-local control service. It is not the steady-state proxy for live traffic. Its jobs are: frp plugin auth, route-state caching, dynamic Caddy route/cert management, and serving startup/unavailable responses for non-live routes.

---

## 5. Technology Choices

### frp (tunnel layer)

**Why frp:**
- Native HTTP vhost routing via `vhostHTTPPort` + `subDomainHost`. A single port handles all subdomains by inspecting the Host header.
- Server plugin system for authorization. We use `Login` and `NewProxy` hooks from day one. frps is not the source of truth for route ownership.
- Client admin API (`/api/reload`) for dynamic config updates without process restart. Enables adding custom domains without VM restart.
- Battle-tested at scale. 87k GitHub stars, widely deployed in production.
- Custom domain support via `customDomains` field in proxy config.

**Why not rathole:**
- rathole is L4-only (TCP forwarding). No HTTP awareness. Each tunnel would need its own port on the server, and a separate reverse proxy to route by Host header. Massive operational complexity vs. frp's native vhost routing.
- No HTTP API for dynamic management. Config file hot-reload only.
- Less battle-tested at scale.

**Why not Cloudflare Tunnel:**
- Vendor lock-in. All user traffic flows through Cloudflare's infrastructure. For a product where app hosting is the core business, owning the networking layer matters.
- Valid choice if operational simplicity is prioritized over control.

**Version:** v0.67.0 (latest stable as of 2026-03)

### Caddy (TLS termination layer)

**Why Caddy:**
- **API-driven cert and route management:** Codapt can proactively register custom domains and provision certs through the Caddy API before a route becomes live. No per-domain shell scripts.
- **Automatic HTTPS:** HTTP→HTTPS redirect, OCSP stapling, cert renewal — all automatic, zero config.
- **Wildcard + dynamic custom-domain hybrid:** Wildcard cert for `*.codapt.ai` via DNS-01 challenge; custom domains are explicitly registered and provisioned by codapt-edge.
- **Storage abstraction:** Caddy has a real shared-storage story for future HA, so we do not have to invent cert replication.

**Why not nginx:**
- nginx + certbot requires per-domain orchestration: obtain cert → write server block → reload. This is manageable at low volume but becomes operationally heavy at scale.
- nginx itself is battle-tested, but the certbot orchestration layer is where fragility lives. Caddy eliminates this layer entirely.
- The team is familiar with nginx, but Caddy's config is simpler (the entire edge proxy config is ~40 lines).

### Transport TLS (frpc ↔ frps encryption)

The frp tunnel between VMs and the edge proxy crosses the network between HelperServers and the edge proxy server. Unless all machines are on the same provider's private network, this traffic traverses untrusted networks.

**Decision: enable TLS on the frp transport.**

```toml
# frps.toml
transport.tls.force = true  # reject non-TLS clients
```

frpc enables TLS by default. `transport.tls.force` on the server makes it mandatory. frp handles the TLS handshake automatically — no certificates to manage for this layer.

This is independent of user-facing HTTPS. There are two TLS layers:

| Layer | What it encrypts | Who handles it |
|---|---|---|
| User-facing HTTPS | browser ↔ edge proxy | Caddy + Let's Encrypt certs |
| frp transport TLS | frpc (VM) ↔ frps (edge proxy) | frp built-in TLS |

---

## 6. Edge Proxy Server Setup

### Prerequisites

- A server with a public IP (small: 2 CPU, 4GB RAM is plenty)
- SSH access
- DNS provider API credentials (for wildcard cert DNS-01 challenge)
- Firewall access to configure allowed ports

### Step 6.1: Provision the server

Get a VPS from your provider (same provider as HelperServers preferred for low latency). You'll have:
- An IP address (e.g., `203.0.113.50`)
- SSH access: `ssh root@203.0.113.50`

### Step 6.2: Install frps

```bash
# on the edge proxy server
FRP_VERSION="0.67.0"
wget "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
tar -xzf "frp_${FRP_VERSION}_linux_amd64.tar.gz"
cp "frp_${FRP_VERSION}_linux_amd64/frps" /usr/local/bin/
rm -rf "frp_${FRP_VERSION}_linux_amd64" "frp_${FRP_VERSION}_linux_amd64.tar.gz"
```

Create `/etc/frps.toml`:

```toml
# Control channel — frpc clients connect here
bindPort = 7000

# HTTP vhost — Caddy forwards decrypted HTTP here
vhostHTTPPort = 8080

# Subdomain base domain
subDomainHost = "codapt.ai"

# Force TLS on tunnel transport
transport.tls.force = true

# Dashboard (optional, for debugging — restrict access via firewall)
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "<GENERATE_ANOTHER_SECRET>"

[[httpPlugins]]
name = "codapt-edge-auth"
addr = "http://127.0.0.1:9090"
path = "/frp-auth"
ops = ["Login", "NewProxy"]
```

**Version pin:** v1 pins both `frps` and `frpc` to `0.67.0`. Do not treat `frp` like a floating dependency. Any upgrade requires a staging compatibility pass covering:
- plugin payloads for `Login` / `NewProxy`
- `metadatas.runtime_id`, `metadatas.credential`, and `metadatas.generation`
- plugin allow response shape (`{"reject": false, "unchange": true}`)
- frpc admin API responses
- reload behavior
- websocket / streaming behavior through `Caddy -> frps -> frpc`

Create `/etc/systemd/system/frps.service`:

```ini
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable frps
systemctl start frps
systemctl status frps  # verify it's running
```

### Step 6.3: Install Caddy (with DNS provider module)

The standard Caddy binary doesn't include DNS provider modules (needed for wildcard cert DNS-01 challenge). Download a custom build from Caddy's download API:

```bash
# Download Caddy with Cloudflare DNS module
# ↑ swap cloudflare for your DNS provider:
#   github.com/caddy-dns/route53           (AWS)
#   github.com/caddy-dns/digitalocean      (DigitalOcean)
#   github.com/caddy-dns/ovh               (OVH)
#   etc. — full list: https://caddyserver.com/docs/modules/
curl -o /usr/local/bin/caddy \
  "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/cloudflare"
chmod +x /usr/local/bin/caddy

# Verify
caddy version
```

Create `/etc/systemd/system/caddy.service`:

```ini
[Unit]
Description=Caddy web server
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5
LimitNOFILE=1048576

# Caddy needs to bind to ports 80/443
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

### Step 6.4: Configure Caddy

Create `/etc/caddy/Caddyfile`:

```caddyfile
{
    # Admin API (operational use, localhost only)
    admin localhost:2019

    # ACME email for Let's Encrypt
    email ops@codapt.ai

    # Single-node v1 uses local storage. When multiple edge nodes are added,
    # switch this to a shared storage backend without changing route logic.
    storage file_system {
        root /var/lib/caddy
    }
}

# Wildcard subdomains (*.codapt.ai)
# Uses DNS-01 challenge for wildcard cert. Exact-host routes are then
# registered dynamically via the Caddy API by codapt-edge.
*.codapt.ai {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }

    respond 404
}
```

**How this works:**

1. **`*.codapt.ai` block** gives Caddy a wildcard cert via DNS-01 challenge. All platform subdomains share this cert. Renewal is automatic.

2. **codapt-edge programs exact-host routes into Caddy.** It registers:
   - `starting` / `draining` hosts -> codapt-edge startup/unavailable handler
   - `live` hosts -> direct reverse proxy to `frps`
   - deleted hosts -> route removed

3. **codapt-edge is not the steady-state live proxy.** Live traffic should go from `Caddy -> frps` directly. codapt-edge owns auth/control logic and non-live responses.

4. **Custom domains are also explicit Caddy routes.** codapt-edge provisions the cert first, then promotes the route live.

5. **WebSockets** work automatically on the live path — Caddy's `reverse_proxy` handles upgrade headers natively.

6. **HTTP→HTTPS redirect** is automatic — Caddy redirects all port-80 traffic to HTTPS by default.

Create the error page at `/var/www/html/custom_50x.html`:

```html
<!DOCTYPE html>
<html>
<head>
    <title>Loading...</title>
    <meta http-equiv="refresh" content="5">
    <style>
        body { font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #fafafa; color: #333; }
        .container { text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <h2>This app is starting up...</h2>
        <p>This page will refresh automatically.</p>
    </div>
</body>
</html>
```

Start Caddy:

```bash
mkdir -p /var/www/html
systemctl daemon-reload
systemctl enable caddy
systemctl start caddy
systemctl status caddy  # verify it's running
```

### Step 6.5: Custom domain support (proactive via Caddy API)

**No edge proxy shell scripts needed.** Unlike the nginx + certbot approach, `codapt-edge` explicitly drives Caddy's API:

| Step | nginx + certbot (old plan) | Caddy + codapt-edge (current plan) |
|------|---------------------------|------------------------------------|
| User adds custom domain | API runs shell script on edge: certbot → nginx config → reload | API updates DB, codapt-edge registers route in Caddy API, cert is provisioned before live |
| First request arrives | Cert already provisioned | Cert should already exist; first user request is not the provisioning path |
| Cert renewal | certbot cron + monitor for failures | Automatic, silent |
| User removes domain | API runs shell script: delete config → reload → delete cert | API updates DB, codapt-edge removes route from Caddy API, frpc config reload |

The thing you need to build is **codapt-edge**, not an `ask` endpoint on the main API server and not a custom always-on live request proxy.

### Step 6.6: Firewall

```bash
# Allow HTTP/HTTPS (public)
ufw allow 80/tcp
ufw allow 443/tcp

# Allow frp control port from the VM fleet's actual egress IPs/CIDRs if known.
# Do not blindly assume these are HelperServer IPs; verify the real NAT/egress path first.
ufw allow from <VM_EGRESS_CIDR_1> to any port 7000
ufw allow from <VM_EGRESS_CIDR_2> to any port 7000
# ... for each known VM egress range

# Deny frp control port from everywhere else (default deny)
ufw deny 7000/tcp

# Enable firewall
ufw enable
```

### Step 6.7: Update DNS

In your DNS provider's dashboard, change the wildcard records to point at the canonical edge target. In v1, that target resolves to the single edge node. Later, the same target can move behind a load balancer or multi-node edge without another customer-facing DNS migration.

```
*.codapt.ai    CNAME/ALIAS    →    edge.codapt.ai
*.trysolid.com CNAME/ALIAS    →    edge.trysolid.com   (if applicable)
```

**Do NOT do this yet during setup.** Do this during the cutover phase (Phase 9) after everything is tested.

---

## 7. Codebase Changes

### 7.1: Environment variables

**File:** `packages/server-lib/src/env.js`

Add:

```javascript
// In the server schema:
EDGE_PROXY_ADDR: z.string(),                    // e.g., "edge.codapt.ai" — canonical edge address used by frpc to connect
EDGE_PROXY_FRP_PORT: z.coerce.number(),          // e.g., 7000
EDGE_PROXY_CANONICAL_TARGET: z.string(),         // canonical DNS target for custom-domain validation, e.g. edge.codapt.ai
```

Note: no `EDGE_PROXY_EXECUTOR_INSTANCE_ID` needed. The edge runs its own long-lived services (`caddy`, `frps`, `codapt-edge`) and is not part of the existing executor flow.

Add corresponding entries to `runtimeEnv` and to `.env` / `prod.env`.

### 7.2: Prisma schema

**File:** `packages/server/prisma/schema.prisma`

Add explicit route and tunnel-lease models. Public routing state should not live on `Vm`.

```diff
model RuntimeRoute {
  id Int @id @default(autoincrement())
  userProjectRuntimeId Int
  hostname String @unique
  localPort Int
  kind String   // "platform_subdomain" | "custom_domain"
  state String  // "reserved" | "app_ready" | "tunnel_connecting" | "tunnel_ready" | "cert_ready" | "live" | "draining" | "stopped" | "failed"
  currentGeneration Int @default(0)
}

model TunnelLease {
  id Int @id @default(autoincrement())
  userProjectRuntimeId Int
  vmId Int
  generation Int
  credentialHash String @unique
  expiresAt DateTime
  revokedAt DateTime?
}

model TunnelSession {
  id Int @id @default(autoincrement())
  userProjectRuntimeId Int
  vmId Int
  generation Int
  edgeNodeId String
  status String   // "connecting" | "connected" | "verified" | "expired" | "revoked"
  connectedAt DateTime?
  lastHeartbeatAt DateTime?
  disconnectedAt DateTime?
}
```

`UserProjectRuntime` keeps `subdomain` and `customDomain` unchanged — these are the user-facing logical fields. `Vm` should not own public-routing authority after cutover.

Use proper Prisma migrations. Do not use `db:push` for production schema changes.

**State-model correction:** the current codebase collapses runtime truth too aggressively. Today `UserProjectRuntime.status` is only `Stopped|Starting|Running|Stopping`, `Vm.status` is separate, and `getUserProjectRuntimeStatus()` flattens both into `Pending|Running|Stopped|Failed`. That is too crude for edge ingress. After cutover:
- `UserProjectRuntime.status` remains coarse VM/app lifecycle
- `RuntimeRoute.state` becomes the source of truth for public readiness
- `TunnelSession.status` becomes the source of truth for observed live reachability
- deployment status APIs should be derived from these explicit states instead of helper-server placement heuristics

### 7.3: VM creation — install frpc

**File:** `packages/server-lib/src/vm-management.ts` → `createVm()`

In the VM initialization script (the `command` variable, lines 326-344), add frpc installation alongside executor-client:

```typescript
const command = dedent`
  #!/bin/bash
  set -e

  # Install Node.js (existing)
  if ! which npx ; then
    echo "Installing nodejs 20..."
    if ! which curl ; then apt-get update && apt-get install --yes curl ; fi
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
  fi

  # Install frpc (new)
  if ! which frpc ; then
    echo "Installing frpc..."
    FRP_VERSION="0.67.0"
    curl -fsSL "https://github.com/fatedier/frp/releases/download/v\${FRP_VERSION}/frp_\${FRP_VERSION}_linux_amd64.tar.gz" | tar -xz
    cp "frp_\${FRP_VERSION}_linux_amd64/frpc" /usr/local/bin/
    rm -rf "frp_\${FRP_VERSION}_linux_amd64"
  fi

  # Create frpc systemd service (new — enabled but not started, starts during deployment)
  ${getWriteFileScript(
    "/etc/systemd/system/frpc.service",
    dedent\`
      [Unit]
      Description=frp tunnel client
      After=network.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/frpc -c /etc/frpc.toml
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    \` + "\\n",
  )}
  systemctl daemon-reload
  systemctl enable frpc
  # Note: frpc is NOT started here. It starts during deployment after frpc.toml is written.

  # Start executor-client (existing)
  if ! systemctl is-active codapt-executor-client; then
    ${getWriteFileScript(
      "/etc/systemd/system/codapt-executor-client.service",
      systemdServiceConfig,
    )}
    systemctl daemon-reload
    systemctl enable codapt-executor-client
    systemctl start codapt-executor-client
  fi
` + "\n";
```

### 7.4: VM start — remove HelperServer public ingress responsibilities

**File:** `packages/server-lib/src/vm-management.ts` → `startVm()`

Do not set up any user-facing proxy rules on the HelperServer.

```diff
  // After start-vm.sh completes:

  // No HelperServer proxy setup here.
  // Public ingress is established later in launchUserProjectRuntime after app
  // readiness, tunnel lease minting, frpc start, and tunnel verification.
```

### 7.5: VM stop — no public-ingress teardown on HelperServers

**File:** `packages/server-lib/src/vm-management.ts` → `stopVm()`

Stopping the VM kills `frpc`, which removes live reachability. `codapt-edge` and route state drive public behavior after that.

```diff
  // No HelperServer proxy teardown here.
  // Tunnel liveness disappears with frpc; codapt-edge should mark the route
  // non-live based on tunnel session expiry.
```

Also remove VM-owned public-routing fields from stop logic:

```diff
  await db.vm.update({
    where: { id: vm.id },
    data: {
      helperServerId: null,
    },
  });
```

### 7.6: Deployment flow — start tunnel after app is ready

**File:** `packages/server-lib/src/user-project-runtime.ts` → `launchUserProjectRuntime()`

After the app is started (after `.codapt/scripts/run` via `launchUprApp()`), and after the readiness check, add a step to write frpc config and start the tunnel:

```typescript
// New helper function
function generateFrpcConfig(opts: {
  edgeProxyAddr: string;
  edgeProxyFrpPort: number;
  tunnelCredential: string;
  routes: Array<{ name: string; localPort: number; subdomain?: string; customDomains?: string[] }>;
}): string {
  let config = dedent`
    serverAddr = "${opts.edgeProxyAddr}"
    serverPort = ${opts.edgeProxyFrpPort}
    transport.tls.enable = true
    metadatas.credential = "${opts.tunnelCredential}"

    webServer.addr = "127.0.0.1"
    webServer.port = 7400
  `;

  for (const proxy of opts.routes) {
    config += `\n\n[[proxies]]\nname = "${proxy.name}"\ntype = "http"\nlocalPort = ${proxy.localPort}\nsubdomain = "${proxy.subdomain}"`;
    if (proxy.customDomains) {
      config += `\ncustomDomains = [${proxy.customDomains.map((d) => `"${d}"`).join(", ")}]`;
    }
  }

  return config;
}
```

In the deployment flow, after app readiness is confirmed:

```typescript
// Write frpc config and start tunnel
const frpcConfig = generateFrpcConfig({
  edgeProxyAddr: env.EDGE_PROXY_ADDR,
  edgeProxyFrpPort: env.EDGE_PROXY_FRP_PORT,
  tunnelCredential: freshlyMintedTunnelLeaseCredential,
  routes: [
    {
      name: "app",
      localPort: 8000,
      subdomain: userProjectRuntime.subdomain,
      customDomains: userProjectRuntime.customDomain
        ? [userProjectRuntime.customDomain]
        : undefined,
    },
  ],
});

await runScriptViaExecutorOrThrow({
  executorInstanceId: vmExecutorInstanceId,
  script: dedent`
    cat > /etc/frpc.toml << 'FRPC_CONFIG_EOF'
    ${frpcConfig}
    FRPC_CONFIG_EOF
    systemctl restart frpc
  `,
});

// Verify tunnel is actually registered — do NOT blindly sleep
await runScriptViaExecutorOrThrow({
  executorInstanceId: vmExecutorInstanceId,
  script: dedent`
    # Poll frpc admin API for an initial local signal.
    # This is necessary but NOT sufficient for final public readiness.
    for i in $(seq 1 5); do
      PROXY_STATUS=$(curl -sf http://127.0.0.1:7400/api/status 2>/dev/null || echo '{}')
      # Check if any proxy has status "running"
      if echo "$PROXY_STATUS" | grep -q '"status".*"running"'; then
        echo "Tunnel established successfully"
        exit 0
      fi
      echo "Waiting for tunnel... attempt $i/5"
      sleep 2
    done
    echo "ERROR: Tunnel failed to establish after 10 seconds" >&2
    exit 1
  `,
});
```

**If the tunnel verification fails**, the deployment should NOT transition to "Running" status. The error should be surfaced to the user. The deployment remains in "Starting" state so the user (and monitoring) knows something is wrong.

**Key design decisions:**
1. The tunnel starts AFTER the app is ready. This eliminates 502 errors during deployment.
2. frpc admin API is an initial local signal only. Final verification must be multi-signal: plugin acceptance, frps registration, and synthetic host probe.
3. The subdomain only becomes reachable once BOTH the app is serving AND the edge confirms live-route readiness.

Default policy: one public app endpoint on local port 8000. Do not preserve legacy 9000/9001 exposure unless product requirements justify explicit additional endpoints.

**Explicit route/tunnel state transitions:**

```text
RuntimeRoute.state
reserved
  -> app_ready              (app passed readiness check in VM)
  -> tunnel_connecting      (lease minted, frpc config written, frpc started)
  -> tunnel_ready           (frpc connected + plugin accepted proxy)
  -> cert_ready             (for custom domains after cert provisioning; platform subdomains may skip straight to live)
  -> live                   (Caddy route points at frps)
  -> draining               (redeploy / stop in progress; stop sending new traffic)
  -> stopped | failed

TunnelSession.status
connecting
  -> connected              (frpc socket established)
  -> verified               (plugin accepted current generation + hostname + port)
  -> expired | revoked | disconnected
```

**Who moves each transition:**
- VM launch flow moves `reserved -> app_ready -> tunnel_connecting`
- frp plugin / codapt-edge moves `tunnel_connecting -> tunnel_ready`
- Caddy provisioning flow moves `tunnel_ready -> cert_ready` for custom domains
- codapt-edge route promotion moves `cert_ready -> live` (or `tunnel_ready -> live` for platform subdomains)
- stop/redeploy flows move `live -> draining -> stopped`

### 7.7: Custom domain — no VM restart

**File:** `packages/api/src/procedures/client-api-v1/deployment/add-custom-domain-to-deployment.ts`

Replace `restartUserProjectRuntime()` with route update + Caddy registration + frpc config reload:

```diff
  // If the deployment was running, update the tunnel config
  if (wasRunning) {
-   await restartUserProjectRuntime({ uprId: userProjectRuntime.id });
+   // Get the VM's executor instance
+   const upr = await db.userProjectRuntime.findUniqueOrThrow({
+     where: { id: userProjectRuntime.id },
+     include: { vm: true },
+   });
+
+   if (upr.vm && upr.vmId) {
+     // Register the custom domain with codapt-edge / Caddy first
+     await registerCustomDomainRoute({
+       uprId: upr.id,
+       hostname: customDomain,
+     });
+
+     // Regenerate frpc config with new custom domain
+     const frpcConfig = generateFrpcConfig({
+       edgeProxyAddr: env.EDGE_PROXY_ADDR,
+       edgeProxyFrpPort: env.EDGE_PROXY_FRP_PORT,
+       tunnelCredential: freshlyMintedTunnelLeaseCredential,
+       routes: [
+         {
+           name: "app",
+           localPort: 8000,
+           subdomain: upr.subdomain,
+           customDomains: [customDomain],
+         },
+       ],
+     });
+
+     await runScriptViaExecutorOrThrow({
+       executorInstanceId: upr.vm.executorInstanceId,
+       script: dedent`
+         cat > /etc/frpc.toml << 'FRPC_CONFIG_EOF'
+         ${frpcConfig}
+         FRPC_CONFIG_EOF
+         curl -s http://127.0.0.1:7400/api/reload
+       `,
+     });
+
+     // Wait for certificate provisioning and route readiness before returning.
+   }
  }
```

This removes the VM restart and moves correctness to the edge. Do not claim zero downtime unless you measure reload behavior under live traffic.

### 7.8: DNS config check — validate against canonical edge target

**File:** `packages/api/src/procedures/client-api-v1/deployment/check-dns-config.ts`

Replace HelperServer IP resolution with canonical target validation:

```diff
- // Get the expected IP address from the helper server
- const helperServerDomain = userProjectRuntime.vm.helperServer?.domain;
- if (!helperServerDomain) { ... }
- const expectedIpResult = await dnsLookup(helperServerDomain, { family: 4 });
-
- // Compare single IP
- const isCorrect = resolvedIp === expectedIpResult.address;

+ // Validate that the custom domain points at the canonical edge target.
+ // Prefer CNAME/ALIAS-style validation; fall back to A/AAAA only where needed.
+ const canonicalTarget = env.EDGE_PROXY_CANONICAL_TARGET;
```

The long-term contract is “point at the edge,” not “point at this list of IPs.”

### 7.9: Update mismatch detection

Public-routing mismatches should no longer be checked on the `Vm` record at all. Route ownership lives in `RuntimeRoute`; VM restarts should only be driven by VM health / executor connectivity.

Key location in `user-project-runtime.ts` (around lines 559-573):

```diff
- // Check if VM subdomain/customDomain matches UPR and restart if mismatched
- if (vm.status === "Running" &&
-     (vm.customDomain !== userProjectRuntime.customDomain ||
-      vm.subdomain !== userProjectRuntime.subdomain ||
-      vm.executorInstance.status !== "Connected")) {
-   await stopVm({ vmId });
-   vmStopped = true;
- }
+ // Only restart if executor is disconnected — subdomain/customDomain mismatches
+ // are handled by frpc config reload, not VM restart
+ if (vm.status === "Running" && vm.executorInstance.status !== "Connected") {
+   await stopVm({ vmId });
+   vmStopped = true;
+ }
```

### 7.10: codapt-edge service (new)

Add a dedicated edge-local service. Do not put this in `packages/api/src/routes/...`; raw HTTP routes in this repo are mounted through Hono.

```typescript
// Responsibilities:
// - frp plugin endpoint for Login/NewProxy authorization
// - Caddy API client / route compiler for host -> upstream registration
// - route cache / readiness cache
// - startup/unavailable responses for non-live hosts
```

`codapt-edge` should not sit in front of every live request. Its job is control/auth glue plus non-live responses; Caddy should proxy live traffic directly to frps.

Place any new raw HTTP endpoints either in this new edge service or under the existing Hono tree in `apps/new-web/src/server/hono/routes/`.

---

## 8. Manual Validation (Proof of Concept)

Do this BEFORE any codebase changes. It proves the architecture works end-to-end.

### Step 8.1: Set up a test edge proxy

Follow Section 6 (steps 6.1-6.5) on a test server. Use a test domain or temporarily use the real domain.

### Step 8.2: Install frpc on an existing running VM

SSH into any running VM (via the executor, or use the HelperServer to get console access). Install frpc manually:

```bash
FRP_VERSION="0.67.0"
wget "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
tar -xzf "frp_${FRP_VERSION}_linux_amd64.tar.gz"
cp "frp_${FRP_VERSION}_linux_amd64/frpc" /usr/local/bin/
```

Create `/etc/frpc.toml`:

```toml
serverAddr = "<EDGE_PROXY_ADDR>"
serverPort = 7000
transport.tls.enable = true

# Carry a one-off lease minted by Codapt for this test tunnel.
# v1 contract on frp 0.67.0 uses these metadata keys.
metadatas.runtime_id = "manual-test"
metadatas.credential = "<SIGNED_TUNNEL_LEASE>"

[[proxies]]
name = "manual-test"
type = "http"
localPort = 8000
subdomain = "manual-test"
```

Run it:

```bash
frpc -c /etc/frpc.toml
```

### Step 8.3: Verify

If DNS is pointed to the canonical edge target:
- Visit `https://manual-test.codapt.ai` in your browser
- You should see the app running on port 8000 in that VM

If DNS is NOT pointed yet (still points to HelperServer):
- Test with curl using the correct SNI/Host combination:
  ```bash
  curl --resolve manual-test.codapt.ai:443:<EDGE_PROXY_IP> https://manual-test.codapt.ai/ --insecure
  ```

### Step 8.4: What to verify

- [ ] HTTP request reaches the app through the tunnel
- [ ] WebSocket connections work (test if the app uses them)
- [ ] Latency is acceptable (measure with `curl -w "%{time_total}\n"`)
- [ ] Stopping frpc makes the subdomain return an error page (not hang)
- [ ] Restarting frpc re-establishes the tunnel automatically
- [ ] Multiple tunnels can coexist on the same frps

**Take a screenshot of the app loading through the tunnel.** This is your proof of concept for the CTO meeting.

### Step 8.5: Required staging spike before implementation

Do **not** start broad repo implementation after the proof of concept alone. First do a staging spike that pins the real behavior of the chosen stack.

**Goal:** replace inference with measured facts.

Build the smallest end-to-end staging setup:
- one edge node running `caddy`, `frps`, and a minimal `codapt-edge`
- one VM running the app plus `frpc`
- one platform subdomain route
- one custom-domain route if possible

Use that staging setup to answer these exact questions:
- [ ] What does the real `frps` plugin payload look like on `Login` and `NewProxy`?
- [ ] Do `metadatas.runtime_id`, `metadatas.credential`, and `metadatas.generation` arrive exactly as expected on `frp 0.67.0`?
- [ ] What does the frpc admin API actually return when a tunnel is connected, disconnected, reloading, or rejected?
- [ ] Does `Caddy -> frps -> frpc` preserve WebSockets, SSE, and streaming responses correctly?
- [ ] What happens during `frpc` reload? Are existing requests or sockets dropped?
- [ ] What happens during `frps` restart? How long until tunnels reconnect?
- [ ] What happens during `caddy` reload? Are requests interrupted?
- [ ] What is the VM fleet's real egress path / CIDR for firewalling?
- [ ] Can `codapt-edge` register a host in Caddy as `starting`, then promote it to `live`, then remove it cleanly?

**Required outputs from the staging spike:**
- a pinned `frp` contract:
  - exact version
  - exact metadata keys
  - exact plugin payload assumptions
  - exact admin API assumptions
- a captured frpc admin API state-response contract (`connected`, `disconnected`, `reload`, `rejected`) with real response bodies and HTTP status codes
- measured reconnect / reload timings
- a yes/no answer on whether any part of the design needs to change before implementation

**Only after this spike is complete** should you start the codebase changes in Section 9.

### Step 8.6: Measured findings from local lab (`tmp/edge-lab`)

We ran a local `docker compose` spike with:
- `caddy` (`tls internal`)
- `frps`/`frpc` pinned to `0.67.0`
- minimal `codapt-edge` auth stub (Node)
- minimal demo app (Node)

Detailed artifacts and captured payloads are in:
- `tmp/edge-lab/MEASUREMENTS.md`
- `tmp/edge-lab/artifacts/*`

Validated end-to-end path:
- `Caddy -> frps -> frpc -> app` preserves:
  - HTTP (`GET /`, `GET /health`)
  - streaming (`GET /sse`)
  - WebSockets (`GET /ws`, echo)
  - uploads (`POST /upload`, byte count)

Milestone sequencing that avoided false confidence:
1. tunnel only (`frps <-> frpc <-> app`)
2. auth plugin checks (`Login` + `NewProxy`)
3. caddy in front (`tls internal`)
4. route-state control (`starting -> live -> removed`)

Freeze these as measured `frp 0.67.0` contract facts:
- `Login` hook metadata arrives at `content.metas`
- `NewProxy` hook metadata arrives at `content.user.metas`
- keys used in this lab are `runtime_id`, `credential`, and `generation` (from frpc `metadatas.*`)
- requested host authorization should be derived from `NewProxy.content.subdomain + subDomainHost` and matched against route allowlist
- allow response should include `unchange: true`:
  - allow: `{"reject": false, "unchange": true}`
  - deny: `{"reject": true, "reject_reason": "..."}`

If `unchange: true` is omitted on allow, `frps` may treat content as modified and surface misleading login failures (we observed `token in login doesn't match token from configuration` during the spike).

Auth matrix validated in local lab:
- good credential / hostname / generation -> accepted
- bad credential -> rejected
- wrong hostname -> rejected
- stale generation -> rejected

Route-state control-plane behavior validated:
- `starting` state serves startup response from codapt-edge
- `live` state proxies directly `Caddy -> frps` (codapt-edge not on live path)
- `removed` state returns `404`

Measured frpc admin API contract (critical):
- connected: `GET /api/status` returns a running proxy object
- disconnected: `GET /api/status` returns `{}`
- rejected auth: `GET /api/status` also returns `{}`
- reload: `GET /api/reload` returns `200` with empty body

This means frpc admin API alone cannot distinguish disconnected vs rejected; production state inference must combine:
- plugin accept/reject events (with reasons)
- frps active proxy presence
- synthetic data-plane probe to expected hostname

Measured local timings (docker on one host; do not assume universal):
- reconnect after `frpc` restart: ~423 ms
- reconnect after `frps` restart: ~2503 ms
- caddy reload probe (`/adapt` + `/load`) did not interrupt the sampled SSE stream in this lab run

Operational pitfalls discovered (do not repeat in production):
- Do not use `HEAD`/`wget --spider` against frps dashboard routes for readiness.
  - `/` returns `301` to `/static/`
  - `HEAD /static/` returns `405 Method Not Allowed`
- Use process liveness plus `GET`-based readiness checks instead:
  - if dashboard auth disabled: `curl -fsS http://127.0.0.1:7500/static/ >/dev/null`
  - if dashboard auth enabled: `curl -fsS -u <user>:<pass> http://127.0.0.1:7500/static/ >/dev/null`
- Local-lab caveat: host port `7000` may already be occupied by unrelated software. Keep `7000` internal-only in local docker tests; expose `8080` for vhost tunnel checks.
- First HTTPS request right after caddy start/reload may fail transiently; use retries/backoff before declaring the route unhealthy.
- Route registration can race caddy startup/reload. `codapt-edge` should retry caddy API operations with backoff and only mark a route ready after push success + synthetic host probe.

---

## 9. Migration & Cutover Plan

### Invariant

There is no backward-compatibility traffic path. We prepare safely, then cut over once. Schema expansion/cleanup may still happen in phases; public ingress does not.

### Phase A: Deploy edge proxy (no impact on production)

1. Provision edge proxy server
2. Install frps + Caddy
3. Obtain wildcard cert
4. Measure the VM fleet's real egress path and restrict frps ingress to those CIDRs if possible
5. Verify frps is running and accepting test tunnels
6. Complete the staging spike in Section 8.5 and freeze the actual `frp` / `codapt-edge` contract
7. Deploy `codapt-edge` on the edge host

**Exit criteria:** The staging spike is complete, a manually-configured frpc on a test VM can serve traffic through the edge proxy, `codapt-edge` is authorizing tunnel registration, and the firewall allowlist is based on measured egress rather than assumption.

### Phase B: Deploy codebase changes (dark launch — no user traffic yet)

1. Add env vars (`EDGE_PROXY_ADDR`, `EDGE_PROXY_FRP_PORT`, `EDGE_PROXY_CANONICAL_TARGET`)
2. Apply schema migration: add `RuntimeRoute` / `TunnelLease`
3. Deploy updated code:
   - `startVm()` no longer creates HelperServer proxy rules
   - `stopVm()` no longer tears down HelperServer proxy rules
   - `launchUserProjectRuntime()` writes frpc.toml and starts frpc after app readiness
   - DNS check validates against canonical edge target
   - Deployment status returns canonical edge target / edge address for custom-domain instructions
4. Install frpc on all existing running VMs via executor script (backfill):
   ```bash
   # For each running UPR: mint tunnel lease, write frpc.toml, start frpc, verify route
   ```
5. Verify all running tunnels are registered on frps dashboard (`http://127.0.0.1:7500`)

**Exit criteria:** Every running deployment has a verified tunnel path to the edge. Use `curl --resolve <host>:443:<EDGE_PROXY_IP> https://<host>/ --insecure` for validation.

### Phase C: Cutover DNS (wildcard)

**Pre-cutover checklist:**
- [ ] All running deployments have active frpc tunnels on the edge
- [ ] Edge proxy wildcard cert is valid and auto-renewing
- [ ] Monitoring/alerting is active on edge proxy (frps process, Caddy, cert expiry)
- [ ] DNS TTL has been lowered to 60s at least 24h before cutover (to speed propagation)

**Cutover:**
1. Flip wildcard DNS: `*.codapt.ai` → canonical edge target (`edge.codapt.ai`, which resolves to the single edge node in v1)
2. Restart/reconcile all running runtimes so every live runtime has a fresh verified tunnel session
3. Wait for DNS propagation (~5 minutes with 60s TTL)
4. Verify: visit several live deployments in browser, confirm they load
5. Monitor error rates for 30 minutes

**Rollback:** Revert application code to the previous release, restore HelperServer proxy behavior, and flip DNS back. There is no live dual-publish fallback.

**Exit criteria:** All wildcard subdomain traffic flows through the edge proxy.

### Phase C.1: Cutover custom domains

Custom domains require per-domain migration because users have A records pointing to individual HelperServer IPs.

1. **Inventory:** Query all UPRs with `customDomain IS NOT NULL` and their current HelperServer IPs
2. **Notify users:** Send notification (email/in-app) to each user with a custom domain:
   - "Your custom domain DNS target is changing. Please update your DNS from `<old_helperserver_ip>` to the canonical edge target (`edge.codapt.ai` or the provider-specific ALIAS/CNAME equivalent). Use the deployment settings page to verify your DNS configuration."
3. **Monitor:** Track which custom domains have updated DNS via periodic `checkDnsConfig` checks
4. **Certificate provisioning is proactive:** Once a user's DNS points to the edge target, Codapt registers the domain in Caddy and waits for the cert before marking the route live.
5. **Deadline:** Set a deadline (e.g., 2 weeks). After the deadline, custom domains still pointing to the old target are cut over or fail.

**Exit criteria:** All active custom domains have DNS pointing to the edge target and have been proactively provisioned in Caddy.

### Phase D: Cleanup

Only proceed after Phase C and C.1 exit criteria are met.

1. Remove any remaining `setup-https-proxy.sh` and `delete-https-proxy.sh` calls from code paths
2. Remove `subdomain`/`customDomain` columns from `Vm` model (schema migration)
3. Remove `subdomain`/`customDomain` nulling from `stopVm()` DB update
4. Remove any remaining `vm.subdomain` / `vm.customDomain` references in codebase
5. Remove HelperServer user-traffic configuration from machine images
6. Remove old proxy scripts from HelperServer image (`/opt/codapt-server-utils/bin/setup-https-proxy*.sh`, `delete-https-proxy*.sh`)

**Exit criteria:** HelperServers have zero user-traffic proxy infrastructure. All ingress flows through the edge proxy.

---

## 10. Failure Modes & Mitigations

### Edge proxy goes down

**Impact:** All user apps unreachable.
**Phase 1 mitigation:** Single edge node with systemd `Restart=always` on both Caddy and frps. frpc reconnects automatically when frps recovers. This is still better than today — currently if a HelperServer's nginx dies, its VMs are unreachable with no failover.
**Future HA (planned, not implemented in v1):** Add multiple edge nodes and shared Caddy storage. Existing long-lived connections will still drop during node failure; this is not a zero-interruption design.

### frpc crashes or disconnects

**Impact:** One user's app becomes unreachable.
**Mitigation:** frpc systemd service has `Restart=always`. It reconnects automatically. frps removes the route when the tunnel drops and re-adds it when frpc reconnects.

### frps crashes

**Impact:** All tunnels disconnect. Same as edge proxy down.
**Mitigation:** systemd `Restart=always`. frpc reconnects when frps comes back. Monitoring/alerting on frps process (see Observability section).

### Caddy cert renewal fails

**Impact:** Wildcard cert expires after 90 days. All HTTPS breaks for subdomains. Custom domain certs expire individually.
**Mitigation:** Caddy auto-renews all certs well before expiry. Monitor cert expiry via Caddy's admin API (`GET http://localhost:2019/certificates`). Alert if any cert is within 14 days of expiry.

### Tunnel verification fails during deployment

**Impact:** User's app is running but unreachable from the internet.
**Mitigation:** Verification must be multi-signal: plugin acceptance (`Login`/`NewProxy`), frps registered proxy presence, and a synthetic HTTP probe to the expected hostname. Treat frpc admin API as advisory only. If verification fails, deployment stays in "Starting" state and the error is surfaced to the user.

### Custom domain cert provisioning fails

**Impact:** Custom domain cannot be promoted to live.
**Mitigation:** Treat cert provisioning as part of route readiness. Do not expose the domain publicly until provisioning succeeds. Retry in control plane; alert on failure.

### HA Design (planned follow-up, not implemented in v1)

v1 runs a single edge node. This is a conscious tradeoff: simpler operations, one ingress SPOF. We still design the control plane and DNS contract so multiple edge nodes can be added later without reworking route ownership.

**What changes for a 1-node v1:**
- Use a canonical hostname like `edge.codapt.ai` from day one, even though it resolves to one node today.
- Use local Caddy filesystem storage on that node now; switch the storage backend later without changing route semantics.
- Run `caddy`, `frps`, and `codapt-edge` on the same host, with internal hops bound to localhost.
- Keep route/tunnel data models edge-node-aware even if there is only one node now.
- Do not build keepalived, VIP failover, or DNS round-robin into v1. Accept the SPOF explicitly and monitor it.

**Planned future topology:** multiple edge nodes + shared Caddy storage backend.

```
                  ┌─────────────────┐
                  │  canonical edge   │  ← DNS *.codapt.ai points here
                  │  target           │
                  └────────┬────────┘
                           │
              ┌────────────┼────────────┐
              ▼                         ▼
     ┌─────────────┐          ┌─────────────┐
     │ Edge Node A  │          │ Edge Node B  │
     │ (future)     │          │ (future)     │
     │ Caddy + frps │          │ Caddy + frps │
     └─────────────┘          └─────────────┘
```

**Design requirements for future HA:**
- Caddy must use a real shared storage backend, not rsync.
- The canonical edge DNS target must already exist in v1 so customers do not need another DNS migration later.
- Tunnel reconnect semantics must be measured and accepted; long-lived connections will drop during node loss unless the architecture changes.

**Why not DNS round-robin:** DNS round-robin with two A records means ~50% of requests fail when one node is down, until clients respect the (often cached) DNS TTL. Not acceptable for a hosting product.

**Why not fully specify HA now:** true multi-node tunnel ingress has real state and reconnect semantics. the important thing for v1 is to avoid painting ourselves into a corner: use a canonical edge target and keep certificate state portable through Caddy storage.

---

## 11. Security

### Tunnel authentication

**Day-one requirement:** No shared frp token. Use per-runtime or per-launch credentials from the start.

Each tunnel lease must be bound to:
- `runtime_id`
- allowed hostnames
- allowed local ports
- generation
- expiry

frps must call the plugin on `Login` and `NewProxy` from day one.

Add an `[[httpPlugins]]` block in frps.toml:

```toml
[[httpPlugins]]
name = "tunnel-auth"
addr = "http://127.0.0.1:9090"
path = "/frp-auth"
ops = ["Login", "NewProxy"]
```

The plugin endpoint (a small HTTP server on the edge proxy, or a call to the codapt API) must validate both hooks:
1. On `Login`, extract `runtime_id` + credential from `content.metas`.
2. On `NewProxy`, extract `runtime_id` + credential + `generation` from `content.user.metas`, and compute requested hostname from `content.subdomain + subDomainHost`.
3. Look up the active `TunnelLease` — is this credential valid, unexpired, and unrevoked?
4. Look up the `RuntimeRoute` associated with this runtime — is this tunnel authorized to register this exact hostname and local port for the current generation?
5. Record or refresh a `TunnelSession` for the accepted generation on this edge node.
6. Return allow as `{"reject": false, "unchange": true}` (important) or deny as `{"reject": true, "reject_reason": "unauthorized"}`.

**What the plugin enforces:** Codapt owns the desired route state (UPR.subdomain, UPR.customDomain). The edge only accepts a live tunnel if the runtime is authorized to serve that hostname. This prevents:
- A compromised VM from hijacking another user's subdomain
- Unauthorized tunnel registrations from rogue frpc clients

### Transport encryption

frp transport TLS is enabled (`transport.tls.force = true`). Tunnel traffic between VMs and the edge proxy is encrypted.

### Firewall

frps control port (7000) should be restricted to the VM fleet's real egress IPs/CIDRs where possible. Do not assume those are HelperServer IPs without verifying the network path. frps dashboard (7500) is bound to localhost only.

### frpc admin API

frpc's admin API (port 7400) is bound to `127.0.0.1`. Only accessible from within the VM.

Measured `frp 0.67.0` behavior in this lab:
- `GET /api/status` returns detailed proxy info when connected
- `GET /api/status` returns `{}` both when disconnected and when auth is rejected
- `GET /api/reload` returns `200` with empty body

Captured examples (`tmp/edge-lab/artifacts/frpc-admin-contract.json`):
- connected body: `{"http":[{"name":"preview-abc-http","type":"http","status":"running","err":"","local_addr":"demo-app:8000","plugin":"","remote_addr":"preview-abc.codapt.local:8080"}]}`
- disconnected body: `{}`
- rejected body: `{}`
- reload body: *(empty)*

Do not use frpc admin API alone as the source of truth for route readiness. Combine it with plugin outcomes and a synthetic request to the expected hostname.

### Caddy admin API

Caddy's admin API (port 2019) is bound to `localhost`. Provides cert management, config reload, and health status. Only accessible from the edge proxy itself.

---

## 12. Observability

Monitoring the edge proxy is critical — it is now a single point of ingress for all user deployments.

### What to monitor

| Metric | Source | Alert threshold |
|--------|--------|-----------------|
| frps process alive | systemd / process check | Down for >10s |
| Caddy process alive | systemd / process check | Down for >10s |
| Active tunnel count | frps dashboard API (`/api/serverinfo`) | Drops >20% in 5 minutes (mass disconnect) |
| Tunnel registration failures | frps logs (grep for "register" errors) | Any occurrence |
| Cert expiry (all) | Caddy admin API: `GET http://localhost:2019/certificates` | <14 days remaining |
| Cert provisioning failures | Caddy logs / codapt-edge route events | Any occurrence |
| codapt-edge health | HTTP health check | Non-200 response |
| Caddy 502/503/504 error rate | Caddy access logs | >5% of requests in 5-minute window |
| Edge proxy CPU/memory/disk | Standard system metrics | CPU >80%, memory >80%, disk >90% |
| frpc tunnel status per UPR (advisory) | frpc admin API on each VM (queried via executor) | Use only with plugin events + synthetic probe |
| frp plugin accept/reject by reason | codapt-edge auth logs/events | Any unexpected reject spike |
| synthetic route probe (expected host -> expected state) | external or edge-local probe | Any mismatch (starting/live/removed) |

### How to implement (minimal)

1. **Cert monitoring via Caddy admin API:** Query `GET http://localhost:2019/certificates` to list all managed certs with expiry dates. Alert if any cert is within 14 days of expiry. Caddy auto-renews well before this, so an alert here indicates a renewal failure.

2. **frps dashboard:** Already configured on `127.0.0.1:7500`. SSH tunnel to view: `ssh -L 7500:localhost:7500 root@<EDGE_PROXY_IP>`. Shows all connected tunnels, traffic stats.
   - Readiness checks must use `GET`, not `HEAD`/`wget --spider`, because dashboard routes commonly return `301` then `405` on `HEAD`.
   - Use:
     - `curl -fsS http://127.0.0.1:7500/static/ >/dev/null` (no auth), or
     - `curl -fsS -u <user>:<pass> http://127.0.0.1:7500/static/ >/dev/null` (with auth).

3. **Caddy access log parsing:** Enable Caddy structured logging (JSON format). Ship logs to your existing observability stack. Key: track 5xx rate by hostname.

4. **Route-readiness contract:** When a deployment transitions to "Running," it means:
   - The app process is running and passed the readiness check
   - The frpc tunnel is connected and verified via plugin acceptance (admin API is advisory only)
   - The route is promoted to `live` in Caddy
   - A synthetic request to the hostname returns expected live behavior

   If any of these fail, the deployment should NOT be marked "Running."

---

## 13. Open Questions for CTO

1. **Where is `codapt.ai` DNS hosted?** Determines which Caddy DNS module to use for the wildcard cert.
2. **Where should the edge proxy server be provisioned?** Same provider/datacenter as HelperServers for lowest latency?
3. **How many concurrent running VMs exist today?** Determines edge proxy sizing and frps capacity planning.
4. **What is the VM fleet's actual egress path?** Firewall policy should be based on measured CIDRs/NAT behavior, not guesses about HelperServers.
5. **Custom domain migration timeline:** How many active custom domains exist? What's an acceptable deadline for users to update their DNS? (Spec proposes 2 weeks.)
6. **Single-node launch posture:** What maintenance window and rollback expectation are acceptable for the one-time traffic cutover?
7. **HA timeline:** We plan multiple edge nodes and shared Caddy storage, but v1 is one node. When do we fund the HA follow-up?
8. **Shared storage choice for future HA:** Which Caddy storage backend fits the infra best?

---

## 14. File Reference

### Files to modify

| File | Change |
|------|--------|
| `packages/server-lib/src/env.js` | Add `EDGE_PROXY_ADDR`, `EDGE_PROXY_FRP_PORT`, `EDGE_PROXY_CANONICAL_TARGET` |
| `packages/server/prisma/schema.prisma` | Add `RuntimeRoute` / `TunnelLease` / `TunnelSession`; remove public-routing semantics from `Vm` |
| `packages/server-lib/src/vm-management.ts` | Add frpc install to `createVm()`; remove old HelperServer proxy code from `startVm()` / `stopVm()` |
| `packages/server-lib/src/user-project-runtime.ts` | Add frpc config write + start after app is ready in `launchUserProjectRuntime()` |
| `packages/api/src/procedures/client-api-v1/deployment/add-custom-domain-to-deployment.ts` | Replace `restartUserProjectRuntime()` with route update + frpc reload + edge registration |
| `apps/edge` or `packages/edge` (new) | `codapt-edge`: frp plugin, Caddy API client, route compiler/cache, startup/unavailable handler |
| `packages/api/src/procedures/client-api-v1/deployment/check-dns-config.ts` | Resolve against canonical edge target instead of HelperServer |
| `packages/api/src/procedures/client-api-v1/deployment/get-deployment-status-subscription.ts` | Break the old API contract: replace `ipAddress` with `dnsTarget` or `edgeTarget`, and return the canonical edge target instead of a HelperServer IP (lines 158-178) |
| `packages/shared-lib/src/shared-types/deployment-api-types.ts` | Replace `ipAddress` with `dnsTarget` / `edgeTarget` and add explicit route readiness fields if needed |
| `packages/api/src/procedures/web-projects/get-web-project.ts` | Propagate the broken-contract rename through embedded deployment status responses |
| `apps/new-web/src/hooks/useWebProjectDeploymentStatus.ts` | Update subscription consumer to the new deployment-status contract |
| `apps/extension/src/webview/hooks/useDeploymentStatusSubscription.ts` | Update subscription consumer to the new deployment-status contract |
| `.env` / `prod.env` | Add new env vars |

### Additional changes (easy to miss)

| File | What | Why |
|------|------|-----|
| `packages/api/src/procedures/client-api-v1/deployment/get-deployment-status-subscription.ts` | Rename the old `ipAddress` field to `dnsTarget` / `edgeTarget`, and derive public readiness from explicit route/tunnel state instead of HelperServer lookup. | The API contract should match the new architecture instead of smuggling hostnames through an IP-shaped field. |
| `packages/server-lib/src/user-project-runtime.ts` | Lines ~559-573: mismatch detection between `vm.subdomain`/`vm.customDomain` and UPR fields triggers a `stopVm`. Remove subdomain/customDomain comparison. Keep executor connection check. | Subdomain mismatches are now handled by frpc config reload, not VM restart. |
| `packages/server-lib/src/worker-scripts/periodic-maintenance.ts` | No changes needed. All maintenance jobs (`stopExpiredTransientUprs`, `startUprsThatShouldBeRunning`, etc.) call `stopVm()`/`startVm()` which are already being updated. | Maintenance flows automatically use the new code path. |
| `packages/api/src/procedures/client-api-v1/get-user-project-runtime-base-domain.ts` | No changes needed. Returns `USER_PROJECT_RUNTIME_BASE_DOMAIN` to frontend for URL display. | Base domain doesn't change. |
| Frontend and extension deployment-status consumers | Audit and update all consumers of `DeploymentStatusResult`, even if they currently only pass the object through. | The type is shared; a hard contract break will ripple through hooks and wrappers. |
| `scripts/deploy` | No changes needed. Manages certs for `app.codapt.ai`, `app.trysolid.com`, `minio.codapt.ai`, `minio-console.codapt.ai` only. These are the platform's own certs, unrelated to user deployment certs. | Platform certs are separate from deployment certs. |

### Where cert machinery currently lives

| Cert type | Current location | New location |
|-----------|-----------------|--------------|
| Platform certs (`app.codapt.ai`, `minio.codapt.ai`, etc.) | `scripts/deploy` runs certbot on the main server | No change — stays on the main server |
| User deployment wildcard cert (`*.codapt.ai`) | `setup-https-proxy.sh` on each HelperServer (not in this repo, at `/opt/codapt-server-utils/bin/`) | Edge proxy: Caddy automatic via DNS-01 challenge (DNS module) |
| Custom domain certs | `setup-https-proxy-custom-domain.sh` on each HelperServer (not in this repo) | Edge proxy: proactive Caddy API registration and cert provisioning |

### Files to read for context

| File | What it contains |
|------|-----------------|
| `packages/server-lib/src/vm-management.ts` | Full VM lifecycle: create, start, stop, delete, helper server selection |
| `packages/server-lib/src/user-project-runtime.ts` | Full deployment flow: UPR creation, launch, app startup, verification |
| `packages/server-lib/src/executor-script-runner.ts` | How scripts are sent to executors and results consumed |
| `packages/server/prisma/schema.prisma` | All database models |
| `packages/api/src/procedures/client-api-v1/deployment/` | All deployment-related tRPC procedures |

---

## 15. Appendix: Technology Evaluation

### frp vs rathole vs alternatives

| Requirement | frp | rathole | Cloudflare Tunnel |
|---|---|---|---|
| HTTP host-header routing | Native (`vhostHTTPPort`) | Not supported (L4 only) | Native (managed) |
| Dynamic tunnel management | Config reload API + server plugin | Config file hot-reload only | API (managed) |
| TLS termination | Needs separate proxy | Needs separate proxy | Built-in (managed) |
| Per-VM auth | Server plugin system | Per-service tokens | Managed auth |
| Multi-port support | Multiple proxy definitions | Multiple services, each on own port | Supported |
| Scale track record | 87k stars, enterprise deployments | Smaller community, some reported issues at ~1300 connections | Massive (Cloudflare infra) |
| Performance | Adequate for HTTP workloads | ~5x less memory, higher throughput | N/A (managed) |
| Vendor lock-in | None (open source, self-hosted) | None | Yes (Cloudflare) |
| Binary size | ~15MB (Go) | ~500KB (Rust) | N/A |

**Decision: frp.** Native HTTP routing is the critical differentiator. rathole would require building an entire routing layer on top.

### nginx vs Caddy for TLS

| Concern | nginx | Caddy |
|---|---|---|
| Wildcard cert | certbot + DNS plugin (one-time setup) | Automatic via DNS module |
| Custom domain cert | certbot per domain + nginx config + reload | Caddy API + proactive provisioning |
| Team familiarity | High (already used everywhere) | Low (new tool) |
| Config complexity | More verbose (~80 lines + per-domain files) | Simpler (~40 lines, no per-domain config) |
| Custom domain orchestration | Edge proxy executor + shell scripts + certbot | None — DB update + frpc reload only |
| Installation | `apt install` | Custom binary download (with DNS module) |
| HA cert sharing | rsync `/etc/letsencrypt/` | Caddy storage modules (S3, Consul, Redis) |

**Decision: Caddy.** The Caddy API and storage model give us a cleaner control plane than certbot-driven shell scripting. We avoid first-request cert issuance as the primary path and provision custom-domain certs before marking routes live.

### frp server plugin (day-one requirement)

frps supports an HTTP plugin system. Six hooks: `Login`, `NewProxy`, `CloseProxy`, `Ping`, `NewWorkConn`, `NewUserConn`.

When a frpc connects and registers a proxy:
1. frps sends a POST to your plugin endpoint with the proxy details (including metadata like the lease credential)
2. Your plugin checks the database: `TunnelLease` valid? → `RuntimeRoute` matches requested hostname and port?
3. Plugin returns `{"reject": false, "unchange": true}` to allow or `{"reject": true, "reject_reason": "..."}` to deny

Measured payload locations on `frp 0.67.0`:
- `Login` metadata: `content.metas.runtime_id`, `content.metas.credential`, `content.metas.generation`
- `NewProxy` metadata: `content.user.metas.runtime_id`, `content.user.metas.credential`, `content.user.metas.generation`
- requested route: `content.subdomain` (convert to hostname via `subDomainHost`)

**Implementation sketch:**
- Small HTTP server (Node.js or Go) running on the edge proxy, listening on `127.0.0.1:9090`
- On `NewProxy` hook: extract `runtime_id` + credential + generation metadata, derive hostname from subdomain, then validate route ownership
- On `Login` hook: validate the presented runtime credential is active and unexpired
- Logging: log all rejections for security audit

This prevents unauthorized tunnel registrations and subdomain hijacking.
