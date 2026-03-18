#!/usr/bin/env bash
set -euo pipefail

docker compose --profile caddy down -v --remove-orphans
