#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts
rm -f artifacts/m4-register-starting.json artifacts/m4-promote-live.json artifacts/m4-remove.json
rm -f artifacts/m4-starting-body.txt artifacts/m4-live-body.txt artifacts/m4-removed-body.txt

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml CADDY_CONFIG=Caddyfile.base \
	docker compose --profile caddy up -d --build demo-app codapt-edge-stub frps frpc caddy

echo "milestone 4: route state control plane"

register_response=""
for _ in $(seq 1 30); do
	register_response="$(curl -fsS -X POST "http://127.0.0.1:9090/route/register-starting" \
		-H "content-type: application/json" \
		-d '{"host":"preview-abc.codapt.local"}' || true)"
	if [[ -n "${register_response}" ]]; then
		break
	fi
	sleep 1
done

if [[ -z "${register_response}" ]]; then
	echo "milestone 4 failed: could not register starting route in codapt-edge" >&2
	exit 1
fi
printf '%s\n' "${register_response}" > artifacts/m4-register-starting.json

starting_body=""
for _ in $(seq 1 30); do
	starting_body="$(curl --noproxy "*" --resolve "preview-abc.codapt.local:443:127.0.0.1" "https://preview-abc.codapt.local/" --insecure -sS || true)"
	if printf '%s\n' "${starting_body}" | rg "state=starting" >/dev/null; then
		break
	fi
	sleep 1
done

if ! printf '%s\n' "${starting_body}" | rg "state=starting" >/dev/null; then
	echo "milestone 4 failed: starting route did not serve startup response" >&2
	exit 1
fi
printf '%s\n' "${starting_body}" > artifacts/m4-starting-body.txt

curl -fsS -X POST "http://127.0.0.1:9090/route/promote-live" \
	-H "content-type: application/json" \
	-d '{"host":"preview-abc.codapt.local"}' > artifacts/m4-promote-live.json

live_body=""
for _ in $(seq 1 30); do
	live_body="$(curl --noproxy "*" --resolve "preview-abc.codapt.local:443:127.0.0.1" "https://preview-abc.codapt.local/" --insecure -sS || true)"
	if printf '%s\n' "${live_body}" | rg "hostname=.*timestamp=" >/dev/null; then
		break
	fi
	sleep 1
done

if ! printf '%s\n' "${live_body}" | rg "hostname=.*timestamp=" >/dev/null; then
	echo "milestone 4 failed: live route did not proxy to app" >&2
	exit 1
fi
if printf '%s\n' "${live_body}" | rg "codapt-edge-stub" >/dev/null; then
	echo "milestone 4 failed: codapt-edge is on the live path" >&2
	exit 1
fi
printf '%s\n' "${live_body}" > artifacts/m4-live-body.txt

curl -fsS -X POST "http://127.0.0.1:9090/route/remove" \
	-H "content-type: application/json" \
	-d '{"host":"preview-abc.codapt.local"}' > artifacts/m4-remove.json

removed_code="$(curl --noproxy "*" --resolve "preview-abc.codapt.local:443:127.0.0.1" "https://preview-abc.codapt.local/" --insecure -sS -o artifacts/m4-removed-body.txt -w "%{http_code}" || true)"
if [[ "${removed_code}" != "404" ]]; then
	echo "milestone 4 failed: expected 404 after remove, got ${removed_code}" >&2
	exit 1
fi

echo "milestone 4 passed"
