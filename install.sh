#!/usr/bin/env bash
# Windows-only shim so you can run install.ps1 from Git Bash.
# This is not a cross-platform installer. It just forwards to PowerShell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -W 2>/dev/null || pwd)"

powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR/install.ps1" "$@"
