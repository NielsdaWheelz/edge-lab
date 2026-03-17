#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p artifacts
rm -f artifacts/m3-curl-root.txt

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml CADDY_CONFIG=Caddyfile.m3 \
	docker compose --profile caddy up -d --build demo-app codapt-edge-stub frps frpc caddy

echo "milestone 3: caddy in front (tls internal)"
echo "test: curl --resolve preview-abc.codapt.local:443:127.0.0.1 https://preview-abc.codapt.local/ --insecure"

body=""
for _ in $(seq 1 40); do
	body="$(curl --noproxy "*" --resolve "preview-abc.codapt.local:443:127.0.0.1" "https://preview-abc.codapt.local/" --insecure -ks || true)"
	if [[ -n "${body}" ]]; then
		break
	fi
	sleep 1
done

if [[ -z "${body}" ]]; then
	echo "milestone 3 failed: caddy->frps->frpc->app path never became reachable" >&2
	exit 1
fi

printf '%s\n' "${body}" | rg "hostname=.*timestamp=" >/dev/null
printf '%s\n' "${body}" > artifacts/m3-curl-root.txt

echo "milestone 3 passed"
