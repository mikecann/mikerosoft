#!/usr/bin/env bash
# Shim so you can run install.ps1 from Git Bash.
# Forwards all arguments to PowerShell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -W 2>/dev/null || pwd)"

powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR/install.ps1" "$@"
