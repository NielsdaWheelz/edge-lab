#!/usr/bin/env bash
set -euo pipefail

host="${LAB_HOST:-preview-abc.codapt.local}"
port="${LAB_PORT:-443}"
base_url="https://${host}"
resolve_arg=(--noproxy "*" --resolve "${host}:${port}:127.0.0.1")

echo "[1/5] GET /"
root_response="$(curl -ksS "${resolve_arg[@]}" "${base_url}/")"
echo "${root_response}"
printf '%s\n' "${root_response}" | rg "hostname=.*timestamp=" >/dev/null

echo "[2/5] GET /health"
health_code="$(curl -ksS -o /dev/null -w "%{http_code}" "${resolve_arg[@]}" "${base_url}/health")"
if [[ "${health_code}" != "200" ]]; then
	echo "health endpoint failed: status=${health_code}" >&2
	exit 1
fi

echo "[3/5] GET /sse"
sse_line="$(curl -ksSN --max-time 5 "${resolve_arg[@]}" "${base_url}/sse" 2>/dev/null | rg "^data: " -m 1 || true)"
if [[ -z "${sse_line}" ]]; then
	echo "sse endpoint did not emit an event" >&2
	exit 1
fi
echo "${sse_line}"

echo "[4/5] POST /upload"
tmp_payload="$(mktemp)"
expected_bytes=16384
dd if=/dev/zero of="${tmp_payload}" bs="${expected_bytes}" count=1 status=none
upload_response="$(curl -ksS "${resolve_arg[@]}" --data-binary @"${tmp_payload}" -X POST "${base_url}/upload")"
rm -f "${tmp_payload}"
echo "${upload_response}"
printf '%s\n' "${upload_response}" | rg "\"bytes\":${expected_bytes}" >/dev/null

echo "[5/5] GET /ws"
docker compose exec -T demo-app env WS_HOST_HEADER="${host}" WS_TARGET_URL="wss://caddy/ws" node /app/ws-smoke.mjs

echo "all smoke checks passed"
