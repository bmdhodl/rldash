#!/usr/bin/env bash
# rldash WSL-side snapshot helper for watch_rl.ps1. Emits 4 sections split by
# @@@: run name, latest progress line, GPU csv, latest driver marker.
#   $1 (optional) = explicit log path
#   RLDASH_DIR  (env, default ~)          = project dir to cd into
#   RLDASH_GLOB (env, default runs/*.log) = which logs to auto-follow
cd "${RLDASH_DIR:-$HOME}" 2>/dev/null || { echo "@@@"; echo "@@@"; echo "@@@"; echo "@@@"; exit 0; }
L="${1:-}"
if [ -z "$L" ]; then
  # shellcheck disable=SC2086
  L=$(ls -t ${RLDASH_GLOB:-runs/*.log} 2>/dev/null | head -1)
fi
D=$(ls -t runs/*driver*.out 2>/dev/null | head -1)
[ -n "$L" ] && basename "$L"
echo "@@@"
[ -n "$L" ] && grep -ahE '^upd' "$L" 2>/dev/null | tail -1
echo "@@@"
nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu \
  --format=csv,noheader,nounits 2>/dev/null | head -1
echo "@@@"
[ -n "$D" ] && grep -ahE 'COMPLETE|ABORT|done .exit' "$D" 2>/dev/null | tail -1
echo "@@@"
# AGE of the log in seconds: a live trainer writes every few seconds, so
# small age == genuinely training; large age == you are looking at history.
[ -n "$L" ] && echo $(( $(date +%s) - $(stat -c %Y "$L") ))
