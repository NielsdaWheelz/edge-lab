# edge-lab measurements

all values below are from live runs in this lab, with artifacts stored under `tmp/edge-lab/artifacts`.

## milestone outcomes

- milestone 1 (`frps <-> frpc <-> app`): pass (`artifacts/m1-curl-root.txt`)
- milestone 2 (auth allow/reject matrix): pass (`artifacts/m2-results.txt`)
- milestone 3 (`caddy -> frps -> frpc -> app`): pass (`artifacts/m3-curl-root.txt`)
- milestone 4 (route state `starting -> live -> removed`): pass (`artifacts/m4-*.txt`)

## exact frps plugin request body

### Login (`artifacts/plugin-login.json`)

```json
{
  "version": "0.1.0",
  "op": "Login",
  "content": {
    "version": "0.67.0",
    "hostname": "372cbfa66b2a",
    "os": "linux",
    "arch": "arm64",
    "privilege_key": "af189b742f10ecba9df7650383dda72b",
    "timestamp": 1773783725,
    "metas": {
      "credential": "cred-good",
      "generation": "gen-2",
      "runtime_id": "runtime-abc"
    },
    "client_spec": {},
    "pool_count": 1,
    "client_address": "172.25.0.6:41574"
  }
}
```

### NewProxy (`artifacts/plugin-newproxy.json`)

```json
{
  "version": "0.1.0",
  "op": "NewProxy",
  "content": {
    "user": {
      "user": "",
      "metas": {
        "credential": "cred-good",
        "generation": "gen-2",
        "runtime_id": "runtime-abc"
      },
      "run_id": "08f6c661cfec6e09"
    },
    "proxy_name": "preview-abc-http",
    "proxy_type": "http",
    "subdomain": "preview-abc"
  }
}
```

## exact frpc admin api responses

captured contract is in `artifacts/frpc-admin-contract.json`.

- connected (`GET /api/status`, HTTP 200):
  - `{"http":[{"name":"preview-abc-http","type":"http","status":"running","err":"","local_addr":"demo-app:8000","plugin":"","remote_addr":"preview-abc.codapt.local:8080"}]}`
- disconnected (`GET /api/status`, HTTP 200):
  - `{}`
- rejected (`GET /api/status`, HTTP 200):
  - `{}`
- reload (`GET /api/reload`, HTTP 200):
  - empty body

## reconnect timings

from `artifacts/measurement-summary.json`:

- reconnect after `frpc` restart: `423 ms`
- reconnect after `frps` restart: `2503 ms`

## caddy reload interruption probe

method:
- keep an SSE stream open on `https://preview-abc.codapt.local/sse`
- trigger `POST /route/reload` through codapt-edge
- observe whether stream process dies immediately

result:
- `caddy_reload_interrupts_sse = false`
- events observed during probe: `7`
- evidence: `artifacts/caddy-reload-sse.log`, `artifacts/caddy-reload-response.json`

## route-state verification outputs

- starting response (`artifacts/m4-starting-body.txt`):
  - `codapt-edge state=starting host=preview-abc.codapt.local`
- live response (`artifacts/m4-live-body.txt`):
  - `hostname=... timestamp=...` (from demo app)
- removed response (`artifacts/m4-removed-body.txt`):
  - `route not found` (HTTP 404)
