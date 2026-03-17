#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/milestone1.sh
./scripts/milestone2.sh
./scripts/milestone3.sh
./scripts/milestone4.sh
./scripts/measurements.sh

echo "all milestones + measurements passed"
