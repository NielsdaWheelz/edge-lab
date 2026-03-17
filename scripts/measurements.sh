#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts

now_ms() {
	python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

wait_for_frpc_running() {
	local timeout_s="${1:-40}"
	local start_s
	start_s="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
	while true; do
		local body
		body="$(curl -sS "http://127.0.0.1:7400/api/status" || true)"
		if printf '%s\n' "${body}" | rg '"status"\s*:\s*"running"' >/dev/null; then
			printf '%s\n' "${body}" > artifacts/frpc-admin-running-latest.json
			return 0
		fi

		local now_s
		now_s="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
		local elapsed
		elapsed="$(python3 - "${start_s}" "${now_s}" <<'PY'
import sys
start = float(sys.argv[1])
now = float(sys.argv[2])
print(now - start)
PY
)"
		local expired
		expired="$(python3 - "${elapsed}" "${timeout_s}" <<'PY'
import sys
elapsed = float(sys.argv[1])
timeout = float(sys.argv[2])
print("1" if elapsed >= timeout else "0")
PY
)"
		if [[ "${expired}" == "1" ]]; then
			echo "timed out waiting for frpc running state" >&2
			return 1
		fi
		sleep 0.25
	done
}

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml CADDY_CONFIG=Caddyfile.base \
	docker compose --profile caddy up -d --build demo-app codapt-edge-stub frps frpc caddy

# Capture fresh plugin payloads from an authenticated registration.
rm -f artifacts/plugin-login.json artifacts/plugin-newproxy.json
: > artifacts/frp-auth-events.ndjson
FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml \
	docker compose up -d --force-recreate frpc

for _ in $(seq 1 30); do
	if [[ -f artifacts/plugin-login.json && -f artifacts/plugin-newproxy.json ]]; then
		break
	fi
	sleep 1
done
if [[ ! -f artifacts/plugin-login.json || ! -f artifacts/plugin-newproxy.json ]]; then
	echo "measurement failed: missing plugin payload captures" >&2
	exit 1
fi

wait_for_frpc_running 40

curl -sS -o artifacts/frpc-admin-connected.json -w "%{http_code}" \
	"http://127.0.0.1:7400/api/status" > artifacts/frpc-admin-connected.code

curl -sS -o artifacts/frpc-admin-reload-response.json -w "%{http_code}" \
	"http://127.0.0.1:7400/api/reload" > artifacts/frpc-admin-reload.code

frpc_restart_start_ms="$(now_ms)"
docker compose restart frpc >/dev/null
wait_for_frpc_running 40
frpc_restart_end_ms="$(now_ms)"
frpc_reconnect_ms=$((frpc_restart_end_ms - frpc_restart_start_ms))

frps_restart_start_ms="$(now_ms)"
docker compose restart frps >/dev/null
wait_for_frpc_running 40
frps_restart_end_ms="$(now_ms)"
frps_reconnect_ms=$((frps_restart_end_ms - frps_restart_start_ms))

docker compose stop frps >/dev/null
sleep 2
curl -sS -o artifacts/frpc-admin-disconnected.json -w "%{http_code}" \
	"http://127.0.0.1:7400/api/status" > artifacts/frpc-admin-disconnected.code || true
docker compose start frps >/dev/null
wait_for_frpc_running 40

: > artifacts/frp-auth-events.ndjson
FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.bad-credential.toml \
	docker compose up -d --force-recreate frpc
sleep 4
curl -sS -o artifacts/frpc-admin-rejected.json -w "%{http_code}" \
	"http://127.0.0.1:7400/api/status" > artifacts/frpc-admin-rejected.code || true

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml \
	docker compose up -d --force-recreate frpc
wait_for_frpc_running 40

python3 - <<'PY'
import json
from pathlib import Path

def read(path):
    p = Path(path)
    return p.read_text().strip() if p.exists() else ""

contract = {
    "connected": {
        "endpoint": "/api/status",
        "http_status": read("artifacts/frpc-admin-connected.code"),
        "body": read("artifacts/frpc-admin-connected.json"),
    },
    "reload": {
        "endpoint": "/api/reload",
        "http_status": read("artifacts/frpc-admin-reload.code"),
        "body": read("artifacts/frpc-admin-reload-response.json"),
    },
    "disconnected": {
        "endpoint": "/api/status",
        "http_status": read("artifacts/frpc-admin-disconnected.code"),
        "body": read("artifacts/frpc-admin-disconnected.json"),
    },
    "rejected": {
        "endpoint": "/api/status",
        "http_status": read("artifacts/frpc-admin-rejected.code"),
        "body": read("artifacts/frpc-admin-rejected.json"),
    },
}
Path("artifacts/frpc-admin-contract.json").write_text(
    json.dumps(contract, indent=2) + "\n",
    encoding="utf-8",
)
PY

curl -fsS -X POST "http://127.0.0.1:9090/route/promote-live" \
	-H "content-type: application/json" \
	-d '{"host":"preview-abc.codapt.local"}' >/dev/null

rm -f artifacts/caddy-reload-sse.log artifacts/caddy-reload-response.json
curl --noproxy "*" --resolve "preview-abc.codapt.local:443:127.0.0.1" \
	"https://preview-abc.codapt.local/sse" --insecure -sSN > artifacts/caddy-reload-sse.log 2>/dev/null &
sse_pid="$!"

sleep 3
if ! kill -0 "${sse_pid}" 2>/dev/null; then
	caddy_reload_interrupted="yes"
else
	curl -fsS -X POST "http://127.0.0.1:9090/route/reload" \
		-H "content-type: application/json" \
		-d '{}' > artifacts/caddy-reload-response.json
	sleep 4
	if kill -0 "${sse_pid}" 2>/dev/null; then
		caddy_reload_interrupted="no"
	else
		caddy_reload_interrupted="yes"
	fi
fi

kill "${sse_pid}" 2>/dev/null || true
wait "${sse_pid}" 2>/dev/null || true

sse_event_count="$(rg '^data:' artifacts/caddy-reload-sse.log -c || true)"

python3 - "${frpc_reconnect_ms}" "${frps_reconnect_ms}" "${caddy_reload_interrupted}" "${sse_event_count}" <<'PY'
import json
import pathlib
import sys

frpc_reconnect_ms = int(sys.argv[1])
frps_reconnect_ms = int(sys.argv[2])
caddy_reload_interrupted = sys.argv[3]
sse_event_count = int(sys.argv[4]) if sys.argv[4].isdigit() else 0

summary = {
    "frpc_reconnect_after_frpc_restart_ms": frpc_reconnect_ms,
    "frpc_reconnect_after_frps_restart_ms": frps_reconnect_ms,
    "caddy_reload_interrupts_sse": caddy_reload_interrupted == "yes",
    "sse_events_observed_during_reload_probe": sse_event_count,
    "artifacts": {
        "plugin_login_request": "artifacts/plugin-login.json",
        "plugin_newproxy_request": "artifacts/plugin-newproxy.json",
        "frpc_admin_connected": "artifacts/frpc-admin-connected.json",
        "frpc_admin_disconnected": "artifacts/frpc-admin-disconnected.json",
        "frpc_admin_reload_response": "artifacts/frpc-admin-reload-response.json",
        "frpc_admin_rejected": "artifacts/frpc-admin-rejected.json",
    },
}
pathlib.Path("artifacts/measurement-summary.json").write_text(
    json.dumps(summary, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "measurements captured in artifacts/"
