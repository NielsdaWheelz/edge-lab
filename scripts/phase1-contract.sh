#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts

phase1_host="preview-abc.codapt.local"
resolve_args=(--noproxy "*" --resolve "${phase1_host}:443:127.0.0.1")
current_step="init"

step() {
	current_step="$1"
	echo "${current_step}"
}

dump_file() {
	local file="$1"
	if [[ -f "${file}" ]]; then
		echo "--- ${file} ---" >&2
		sed -n '1,200p' "${file}" >&2
	fi
}

on_error() {
	local exit_code=$?
	set +e
	echo "phase 1 contract failed at step: ${current_step}" >&2
	echo "--- docker compose ps -a ---" >&2
	docker compose ps -a >&2 || true
	echo "--- recent auth events ---" >&2
	tail -n 40 artifacts/frp-auth-events.ndjson >&2 || true
	dump_file artifacts/phase1-last-response.json
	dump_file artifacts/phase1-state.json
	dump_file artifacts/phase1-state-final.json
	dump_file artifacts/phase1-request-publish-gen2.json
	dump_file artifacts/phase1-request-publish-gen3.json
	dump_file artifacts/phase1-reconcile-gen2.json
	dump_file artifacts/phase1-reconcile-gen3.json
	dump_file artifacts/phase1-no-desired-body.txt
	dump_file artifacts/phase1-starting-gen2.txt
	dump_file artifacts/phase1-live-gen2.txt
	dump_file artifacts/phase1-live-gen3.txt
	echo "--- docker compose logs ---" >&2
	docker compose logs --tail=120 frps caddy codapt-edge-stub frpc frpc-alt >&2 || true
	exit "${exit_code}"
}

trap on_error ERR

reset_artifacts() {
	rm -f \
		artifacts/phase1-*.json \
		artifacts/phase1-*.txt \
		artifacts/plugin-login.json \
		artifacts/plugin-newproxy.json \
		artifacts/plugin-ping.json \
		artifacts/plugin-closeproxy.json \
		artifacts/caddy-active.caddyfile \
		artifacts/route-events.ndjson \
		artifacts/route-state.json
	: > artifacts/frp-auth-events.ndjson
}

assert_valid_json() {
	local file="$1"
	python3 - "${file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
json.loads(path.read_text())
PY
}

json_value() {
	local file="$1"
	local pointer="$2"
	python3 - "${file}" "${pointer}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pointer = sys.argv[2]
value = json.loads(path.read_text())

parts = [part.replace("~1", "/").replace("~0", "~") for part in pointer.split("/") if part]

for part in parts:
    if isinstance(value, dict):
        if part not in value:
            sys.stderr.write(f"missing json pointer {pointer} in {path}\n")
            raise SystemExit(2)
        value = value[part]
        continue
    sys.stderr.write(f"json pointer {pointer} does not resolve in {path}\n")
    raise SystemExit(2)

if value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

assert_json_equals() {
	local file="$1"
	local pointer="$2"
	local expected="$3"
	local actual
	actual="$(json_value "${file}" "${pointer}")"
	if [[ "${actual}" != "${expected}" ]]; then
		echo "json assertion failed: ${file} ${pointer} expected '${expected}' got '${actual}'" >&2
		dump_file "${file}"
		return 1
	fi
}

assert_json_true() {
	assert_json_equals "$1" "$2" "true"
}

assert_json_null() {
	assert_json_equals "$1" "$2" "null"
}

assert_file_contains() {
	local file="$1"
	local needle="$2"
	local contents
	contents="$(cat "${file}")"
	if [[ "${contents}" != *"${needle}"* ]]; then
		echo "text assertion failed: ${file} missing '${needle}'" >&2
		dump_file "${file}"
		return 1
	fi
}

phase1_post_json() {
	local path="$1"
	local body="$2"
	local out_file="$3"
	local expected_code="${4:-200}"
	local code
	code="$(
		curl -sS -o "${out_file}" -w "%{http_code}" -X POST "http://127.0.0.1:9090${path}" \
			-H "content-type: application/json" \
			--data-binary "${body}"
	)"
	cp "${out_file}" artifacts/phase1-last-response.json
	assert_valid_json "${out_file}"
	if [[ "${code}" != "${expected_code}" ]]; then
		echo "POST ${path} expected status ${expected_code}, got ${code}" >&2
		dump_file "${out_file}"
		return 1
	fi
}

phase1_get_json() {
	local url="$1"
	local out_file="$2"
	local expected_code="${3:-200}"
	local code
	code="$(curl -sS -o "${out_file}" -w "%{http_code}" "${url}")"
	assert_valid_json "${out_file}"
	if [[ "${code}" != "${expected_code}" ]]; then
		echo "GET ${url} expected status ${expected_code}, got ${code}" >&2
		dump_file "${out_file}"
		return 1
	fi
}

fetch_phase1_state() {
	local out_file="$1"
	phase1_get_json "http://127.0.0.1:9090/phase1/state" "${out_file}" 200
}

wait_for_file() {
	local file="$1"
	local timeout_s="${2:-30}"
	for _ in $(seq 1 "${timeout_s}"); do
		if [[ -f "${file}" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for ${file}" >&2
	return 1
}

wait_for_http_code() {
	local url="$1"
	local expected_code="$2"
	local out_file="$3"
	local timeout_s="${4:-30}"
	local code=""
	local err_file="${out_file}.err"
	for _ in $(seq 1 "${timeout_s}"); do
		code="$(curl -sS -o "${out_file}" -w "%{http_code}" "${url}" 2>"${err_file}" || true)"
		if [[ "${code}" == "${expected_code}" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for ${url} status ${expected_code}; last status=${code}" >&2
	dump_file "${out_file}"
	dump_file "${err_file}"
	return 1
}

wait_for_event() {
	local file="$1"
	local op="$2"
	local generation_public_id="$3"
	local reject="$4"
	local reason_substring="${5:-}"
	local timeout_s="${6:-30}"
	for _ in $(seq 1 "${timeout_s}"); do
		if python3 - "${file}" "${op}" "${generation_public_id}" "${reject}" "${reason_substring}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
op = sys.argv[2]
generation_public_id = sys.argv[3]
reject = sys.argv[4].lower() == "true"
reason_substring = sys.argv[5]

if not path.exists():
    raise SystemExit(1)

for line in path.read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    event = json.loads(line)
    if event.get("op") != op:
        continue
    if generation_public_id and event.get("generationPublicId") != generation_public_id:
        continue
    if bool(event.get("reject")) != reject:
        continue
    if reason_substring:
        reasons = event.get("reasons") or []
        if not any(reason_substring in reason for reason in reasons):
            continue
    raise SystemExit(0)

raise SystemExit(1)
PY
		then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for event op=${op} generation=${generation_public_id} reject=${reject} reason=${reason_substring}" >&2
	tail -n 40 "${file}" >&2 || true
	return 1
}

wait_for_caddy_admin() {
	local timeout_s="${1:-40}"
	for _ in $(seq 1 "${timeout_s}"); do
		if docker compose exec -T caddy wget -qO- http://127.0.0.1:2019/config/ > artifacts/phase1-caddy-admin.json 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for caddy admin api" >&2
	return 1
}

wait_for_root_contains() {
	local needle="$1"
	local out_file="$2"
	local timeout_s="${3:-30}"
	local expected_code="${4:-200}"
	local code=""
	local body=""
	local err_file="${out_file}.err"
	for _ in $(seq 1 "${timeout_s}"); do
		code="$(curl -ksS "${resolve_args[@]}" "https://${phase1_host}/" -o "${out_file}" -w "%{http_code}" 2>"${err_file}" || true)"
		body="$(cat "${out_file}" 2>/dev/null || true)"
		if [[ "${code}" == "${expected_code}" && "${body}" == *"${needle}"* ]]; then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for public host substring '${needle}' with status ${expected_code}; last status=${code}" >&2
	echo "${body}" >&2
	dump_file "${err_file}"
	return 1
}

wait_for_root_code() {
	local expected_code="$1"
	local body_file="$2"
	local timeout_s="${3:-30}"
	local code=""
	local err_file="${body_file}.err"
	for _ in $(seq 1 "${timeout_s}"); do
		code="$(curl -ksS "${resolve_args[@]}" "https://${phase1_host}/" -o "${body_file}" -w "%{http_code}" 2>"${err_file}" || true)"
		if [[ "${code}" == "${expected_code}" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "timed out waiting for public host status ${expected_code}; last status=${code}" >&2
	dump_file "${body_file}"
	dump_file "${err_file}"
	return 1
}

wait_for_reconcile_live() {
	local generation_public_id="$1"
	local out_file="$2"
	local timeout_s="${3:-30}"
	for _ in $(seq 1 "${timeout_s}"); do
		phase1_post_json "/phase1/reconcile" '{}' "${out_file}" 200
		fetch_phase1_state artifacts/phase1-state.json
		if [[ "$(json_value "${out_file}" "/ok")" == "true" ]] && [[ "$(json_value artifacts/phase1-state.json "/liveGenerationPublicId")" == "${generation_public_id}" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "timed out reconciling desired generation ${generation_public_id} live" >&2
	dump_file "${out_file}"
	dump_file artifacts/phase1-state.json
	return 1
}

step "phase 1 contract: clean previous lab state"
./scripts/down.sh >/dev/null 2>&1 || true
reset_artifacts

step "phase 1 contract: start core services"
FRPS_CONFIG=frps.phase1.toml docker compose up -d --build \
	demo-app demo-app-gen2 demo-app-gen3 codapt-edge-stub frps
wait_for_http_code "http://127.0.0.1:9090/health" 200 artifacts/phase1-edge-health.txt 40
wait_for_http_code "http://127.0.0.1:7500/static/" 200 artifacts/phase1-frps-health.txt 40

step "phase 1 contract: start caddy after core health"
FRPS_CONFIG=frps.phase1.toml CADDY_CONFIG=Caddyfile.base docker compose --profile caddy up -d caddy
wait_for_caddy_admin 40

step "phase 1 contract: reset phase-1 state"
phase1_post_json "/phase1/reset" '{}' artifacts/phase1-reset.json 200
assert_json_true artifacts/phase1-reset.json "/ok"
fetch_phase1_state artifacts/phase1-state-after-reset.json
assert_json_null artifacts/phase1-state-after-reset.json "/desiredGenerationPublicId"
assert_json_null artifacts/phase1-state-after-reset.json "/liveGenerationPublicId"

step "phase 1 contract: reject bad lease"
: > artifacts/frp-auth-events.ndjson
FRPS_CONFIG=frps.phase1.toml FRPC_CONFIG=frpc.phase1.bad-lease.toml docker compose up -d --force-recreate frpc
wait_for_event artifacts/frp-auth-events.ndjson "Login" "gpub2" "true" "lease token mismatch" 20
wait_for_http_code "http://127.0.0.1:7400/api/status" 200 artifacts/phase1-bad-lease-status.json 20

step "phase 1 contract: reject wrong proxy name"
: > artifacts/frp-auth-events.ndjson
FRPS_CONFIG=frps.phase1.toml FRPC_CONFIG=frpc.phase1.wrong-proxy.toml docker compose up -d --force-recreate frpc
wait_for_event artifacts/frp-auth-events.ndjson "NewProxy" "gpub2" "true" "proxy_name mismatch" 20

step "phase 1 contract: start dual verified generations"
rm -f artifacts/plugin-login.json artifacts/plugin-newproxy.json artifacts/plugin-ping.json artifacts/plugin-closeproxy.json
: > artifacts/frp-auth-events.ndjson
FRPS_CONFIG=frps.phase1.toml FRPC_CONFIG=frpc.phase1.gen2.toml FRPC_ALT_CONFIG=frpc.phase1.gen3.toml \
	docker compose up -d --force-recreate frpc frpc-alt
wait_for_file artifacts/plugin-login.json 30
wait_for_file artifacts/plugin-newproxy.json 30
wait_for_event artifacts/frp-auth-events.ndjson "NewProxy" "gpub2" "false" "" 30
wait_for_event artifacts/frp-auth-events.ndjson "NewProxy" "gpub3" "false" "" 30
fetch_phase1_state artifacts/phase1-state-after-dual-verify.json

step "phase 1 contract: no desired generation means no public route"
wait_for_root_code 404 artifacts/phase1-no-desired-body.txt 20
assert_file_contains artifacts/phase1-no-desired-body.txt "route not found"

step "phase 1 contract: explicit publish request for gen2"
phase1_post_json "/phase1/request-publish" '{"generation_public_id":"gpub2"}' artifacts/phase1-request-publish-gen2.json 200
assert_json_true artifacts/phase1-request-publish-gen2.json "/ok"
assert_json_equals artifacts/phase1-request-publish-gen2.json "/phase1/desiredGenerationPublicId" "gpub2"
assert_json_null artifacts/phase1-request-publish-gen2.json "/phase1/liveGenerationPublicId"
fetch_phase1_state artifacts/phase1-state-after-request-publish-gen2.json
assert_json_equals artifacts/phase1-state-after-request-publish-gen2.json "/desiredGenerationPublicId" "gpub2"
assert_json_null artifacts/phase1-state-after-request-publish-gen2.json "/liveGenerationPublicId"
wait_for_root_contains "state=starting" artifacts/phase1-starting-gen2.txt 20 200
wait_for_reconcile_live "gpub2" artifacts/phase1-reconcile-gen2.json 30
wait_for_root_contains "label=gen2 " artifacts/phase1-live-gen2.txt 20 200
fetch_phase1_state artifacts/phase1-state-after-live-gen2.json
assert_json_equals artifacts/phase1-state-after-live-gen2.json "/liveGenerationPublicId" "gpub2"
assert_json_equals artifacts/phase1-state-after-live-gen2.json "/routes/preview-abc.codapt.local/upstreamHost" "g-gpub2-preview-abc.codapt.local"

step "phase 1 contract: publishing gen3 keeps gen2 live until reconcile"
phase1_post_json "/phase1/request-publish" '{"generation_public_id":"gpub3"}' artifacts/phase1-request-publish-gen3.json 200
assert_json_true artifacts/phase1-request-publish-gen3.json "/ok"
assert_json_equals artifacts/phase1-request-publish-gen3.json "/phase1/desiredGenerationPublicId" "gpub3"
assert_json_equals artifacts/phase1-request-publish-gen3.json "/phase1/liveGenerationPublicId" "gpub2"
fetch_phase1_state artifacts/phase1-state-after-request-publish-gen3.json
assert_json_equals artifacts/phase1-state-after-request-publish-gen3.json "/desiredGenerationPublicId" "gpub3"
assert_json_equals artifacts/phase1-state-after-request-publish-gen3.json "/liveGenerationPublicId" "gpub2"
wait_for_root_contains "label=gen2 " artifacts/phase1-still-live-gen2.txt 10 200
wait_for_reconcile_live "gpub3" artifacts/phase1-reconcile-gen3.json 30
wait_for_root_contains "label=gen3 " artifacts/phase1-live-gen3.txt 20 200
fetch_phase1_state artifacts/phase1-state-after-live-gen3.json
assert_json_equals artifacts/phase1-state-after-live-gen3.json "/desiredGenerationPublicId" "gpub3"
assert_json_equals artifacts/phase1-state-after-live-gen3.json "/liveGenerationPublicId" "gpub3"
assert_json_equals artifacts/phase1-state-after-live-gen3.json "/routes/preview-abc.codapt.local/upstreamHost" "g-gpub3-preview-abc.codapt.local"

step "phase 1 contract: old generation must be stopped explicitly, then future reconnect is rejected"
docker compose stop frpc >/dev/null
wait_for_event artifacts/frp-auth-events.ndjson "CloseProxy" "gpub2" "false" "" 20
wait_for_file artifacts/plugin-closeproxy.json 20
FRPS_CONFIG=frps.phase1.toml FRPC_CONFIG=frpc.phase1.gen2.toml docker compose up -d --force-recreate frpc
wait_for_event artifacts/frp-auth-events.ndjson "Login" "gpub2" "true" "lease token revoked" 20
sleep 2
wait_for_root_contains "label=gen3 " artifacts/phase1-live-gen3-post-revoke.txt 20 200
fetch_phase1_state artifacts/phase1-state-final.json

python3 - <<'PY'
import json
from pathlib import Path

def read_json(path, required=True):
    p = Path(path)
    if not p.exists():
        if required:
            raise AssertionError(f"required file missing: {path}")
        return None
    return json.loads(p.read_text())

def read_text(path):
    return Path(path).read_text()

events = []
events_path = Path("artifacts/frp-auth-events.ndjson")
if events_path.exists():
    for raw in events_path.read_text().splitlines():
        line = raw.strip()
        if line:
            events.append(json.loads(line))

def matching_events(op=None, generation_public_id=None, reject=None):
    matches = []
    for event in events:
        if op is not None and event.get("op") != op:
            continue
        if generation_public_id is not None and event.get("generationPublicId") != generation_public_id:
            continue
        if reject is not None and bool(event.get("reject")) != reject:
            continue
        matches.append(event)
    return matches

def first_event(op=None, generation_public_id=None, reject=None):
    matches = matching_events(op, generation_public_id, reject)
    return matches[0] if matches else None

plugin_login = read_json("artifacts/plugin-login.json")
plugin_newproxy = read_json("artifacts/plugin-newproxy.json")
plugin_closeproxy = read_json("artifacts/plugin-closeproxy.json")
plugin_ping_path = Path("artifacts/plugin-ping.json")

state_after_publish_gen3 = read_json("artifacts/phase1-state-after-request-publish-gen3.json")
final_state = read_json("artifacts/phase1-state-final.json")

successful_logins = matching_events("Login", reject=False)
assert len(successful_logins) >= 2, "expected at least two successful Login events"
assert all(event.get("loginRunId") is None for event in successful_logins), "Login unexpectedly carried run_id"

privilege_keys = [event.get("privilegeKey") for event in successful_logins if event.get("privilegeKey")]
assert len(privilege_keys) >= 2, "expected successful Login events to carry privilege_key"
assert len(set(privilege_keys)) < len(privilege_keys), "expected duplicate privilege_key across concurrent successful Login events"

gen2_newproxy = first_event("NewProxy", "gpub2", False)
gen2_closeproxy = first_event("CloseProxy", "gpub2", False)
assert gen2_newproxy is not None, "missing successful NewProxy event for gpub2"
assert gen2_closeproxy is not None, "missing CloseProxy event for gpub2"
assert gen2_newproxy.get("sessionKey"), "NewProxy missing run_id-backed sessionKey"
assert gen2_newproxy.get("sessionKey") == gen2_closeproxy.get("sessionKey"), "NewProxy and CloseProxy did not share run_id-backed sessionKey"

assert plugin_login.get("content", {}).get("run_id") is None, "raw Login payload unexpectedly carried run_id"
assert plugin_newproxy.get("content", {}).get("user", {}).get("run_id"), "raw NewProxy payload missing user.run_id"
assert plugin_closeproxy.get("content", {}).get("user", {}).get("run_id"), "raw CloseProxy payload missing user.run_id"

assert state_after_publish_gen3.get("desiredGenerationPublicId") == "gpub3", "desired generation did not move to gpub3 before reconcile"
assert state_after_publish_gen3.get("liveGenerationPublicId") == "gpub2", "live generation changed before reconcile"
assert "label=gen2 " in read_text("artifacts/phase1-still-live-gen2.txt"), "public host stopped serving gen2 before reconcile"

revoked_login_gen2 = first_event("Login", "gpub2", True)
assert revoked_login_gen2 is not None, "missing rejected Login after revocation"
assert any("lease token revoked" in reason for reason in (revoked_login_gen2.get("reasons") or [])), "revoked Login did not report lease token revoked"
post_revoke_newproxy = [
    event
    for event in matching_events("NewProxy", "gpub2")
    if event.get("ts", "") > revoked_login_gen2.get("ts", "")
]
assert not post_revoke_newproxy, "revoked reconnect reached NewProxy after rejected Login"

assert final_state.get("desiredGenerationPublicId") == "gpub3", "final desired generation was not gpub3"
assert final_state.get("liveGenerationPublicId") == "gpub3", "final live generation was not gpub3"
assert final_state.get("routes", {}).get("preview-abc.codapt.local", {}).get("upstreamHost") == "g-gpub3-preview-abc.codapt.local", "final public route upstream host was not gpub3 transport host"
assert "label=gen3 " in read_text("artifacts/phase1-live-gen3.txt"), "public cutover never served gen3"
assert "label=gen3 " in read_text("artifacts/phase1-live-gen3-post-revoke.txt"), "public host regressed after revoked reconnect"

ping_events = matching_events("Ping")
assert not ping_events, "measured contract changed: Ping was observed during phase-1 harness window"
assert not plugin_ping_path.exists(), "measured contract changed: plugin-ping.json was captured"

summary = {
    "assertions": {
        "login_has_no_run_id": True,
        "duplicate_login_privilege_key_observed": True,
        "newproxy_and_closeproxy_share_run_id": True,
        "desired_live_separation_holds_before_reconcile": True,
        "revoked_reconnect_rejected_before_newproxy": True,
        "public_cutover_serves_new_generation": True,
        "ping_not_observed_in_harness_window": True,
    },
    "login": {
        "raw_login_run_id": plugin_login.get("content", {}).get("run_id"),
        "raw_login_privilege_key": plugin_login.get("content", {}).get("privilege_key"),
        "successful_login_privilege_keys": privilege_keys,
    },
    "session_correlation": {
        "gen2_newproxy_run_id": gen2_newproxy.get("sessionKey"),
        "gen2_closeproxy_run_id": gen2_closeproxy.get("sessionKey"),
        "raw_newproxy_run_id": plugin_newproxy.get("content", {}).get("user", {}).get("run_id"),
        "raw_closeproxy_run_id": plugin_closeproxy.get("content", {}).get("user", {}).get("run_id"),
    },
    "publication": {
        "desired_after_publish_gen3": state_after_publish_gen3.get("desiredGenerationPublicId"),
        "live_before_reconcile_gen3": state_after_publish_gen3.get("liveGenerationPublicId"),
        "final_desired_generation": final_state.get("desiredGenerationPublicId"),
        "final_live_generation": final_state.get("liveGenerationPublicId"),
        "final_public_route_upstream_host": final_state.get("routes", {}).get("preview-abc.codapt.local", {}).get("upstreamHost"),
    },
    "revocation": {
        "revoked_login_reasons": revoked_login_gen2.get("reasons"),
        "post_revoke_newproxy_events": post_revoke_newproxy,
    },
    "artifacts": {
        "plugin_login": "artifacts/plugin-login.json",
        "plugin_newproxy": "artifacts/plugin-newproxy.json",
        "plugin_closeproxy": "artifacts/plugin-closeproxy.json",
        "frp_auth_events": "artifacts/frp-auth-events.ndjson",
        "state_after_publish_gen3": "artifacts/phase1-state-after-request-publish-gen3.json",
        "state_final": "artifacts/phase1-state-final.json",
        "caddy_active": "artifacts/caddy-active.caddyfile",
    },
}

Path("artifacts/phase1-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

echo "phase 1 contract passed"
