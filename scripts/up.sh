#!/usr/bin/env bash
set -euo pipefail

FRPS_CONFIG=frps.m2.toml FRPC_CONFIG=frpc.good.toml CADDY_CONFIG=Caddyfile.base \
	docker compose --profile caddy up -d --build demo-app codapt-edge-stub frps frpc caddy
docker compose --profile caddy ps
