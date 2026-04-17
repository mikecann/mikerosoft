#!/usr/bin/env bash
# kill.sh - stop the mac-screenshot daemon.
# Usage:  bash tools/mac-screenshot/kill.sh

pkill -f "mac-screenshot.py" 2>/dev/null && echo "mac-screenshot stopped." || echo "No running instance found."
