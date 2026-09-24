#!/usr/bin/env bash

pkill -f "[f]ilmora_hotkey.py" 2>/dev/null \
  && echo "filmora-hotkey stopped." \
  || echo "No filmora-hotkey instance was running."
