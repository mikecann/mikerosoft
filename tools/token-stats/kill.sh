#!/usr/bin/env bash

set -euo pipefail

pkill -x token-stats-swift 2>/dev/null || true
