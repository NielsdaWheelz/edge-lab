#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts
rm -f artifacts/m2-results.txt artifacts/plugin-login.json artifacts/plugin-newproxy.json
: > artifacts/frp-auth-events.ndjson

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml \
	docker compose up -d --build demo-app codapt-edge-stub frps frpc

run_case() {
	local cfg="$1"
	local label="$2"
	local expect="$3"
	local reason_pattern="${4:-}"

	: > artifacts/frp-auth-events.ndjson
	FRPS_CONFIG=frps.m2.toml FRPC_CONFIG="${cfg}" \
		docker compose up -d --force-recreate frpc

	sleep 4

	local body_file="artifacts/m2-${label}-curl.txt"
	local code
	code="$(curl -sS -o "${body_file}" -w "%{http_code}" -H "Host: preview-abc.codapt.local" "http://localhost:8080/" || true)"

	if [[ "${expect}" == "accept" ]]; then
		if [[ "${code}" != "200" ]]; then
			echo "case ${label} failed: expected 200, got ${code}" >&2
			exit 1
		fi
		rg '"op":"Login".*"reject":false' artifacts/frp-auth-events.ndjson >/dev/null
		rg '"op":"NewProxy".*"reject":false' artifacts/frp-auth-events.ndjson >/dev/null
	else
		if [[ "${code}" == "200" ]]; then
			echo "case ${label} failed: expected non-200, got 200" >&2
			exit 1
		fi
		rg "${reason_pattern}" artifacts/frp-auth-events.ndjson >/dev/null
	fi

	echo "case=${label} expect=${expect} code=${code}" | tee -a artifacts/m2-results.txt
}

echo "milestone 2: route-scoped auth"

run_case "frpc.good.toml" "good" "accept"

for _ in $(seq 1 20); do
	if [[ -f artifacts/plugin-login.json && -f artifacts/plugin-newproxy.json ]]; then
		break
	fi
	sleep 1
done

if [[ ! -f artifacts/plugin-login.json || ! -f artifacts/plugin-newproxy.json ]]; then
	echo "milestone 2 failed: plugin payload artifacts were not captured" >&2
	exit 1
fi

run_case "frpc.bad-credential.toml" "bad-credential" "reject" "credential mismatch"
run_case "frpc.wrong-host.toml" "wrong-host" "reject" "hostname mismatch"
run_case "frpc.stale-generation.toml" "stale-generation" "reject" "generation mismatch"

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml \
	docker compose up -d --force-recreate frpc

echo "milestone 2 passed"
