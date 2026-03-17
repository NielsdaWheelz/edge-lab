#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts
rm -f artifacts/m1-curl-root.txt

docker compose down -v --remove-orphans >/dev/null 2>&1 || true

FRPS_CONFIG=frps.m1.toml FRPC_CONFIG=frpc.m1.toml \
	docker compose up -d --build demo-app frps frpc

echo "milestone 1: tunnel only"
echo "test: curl -H 'Host: preview-abc.codapt.local' http://localhost:8080/"

body=""
for _ in $(seq 1 40); do
	body="$(curl -fsS -H "Host: preview-abc.codapt.local" "http://localhost:8080/" || true)"
	if [[ -n "${body}" ]]; then
		break
	fi
	sleep 1
done

if [[ -z "${body}" ]]; then
	echo "milestone 1 failed: tunnel path did not become reachable" >&2
	exit 1
fi

printf '%s\n' "${body}" | rg "hostname=.*timestamp=" >/dev/null
printf '%s\n' "${body}" > artifacts/m1-curl-root.txt

echo "milestone 1 passed"
