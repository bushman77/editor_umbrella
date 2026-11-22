#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

prompt_file="${1:-.qwen/prompts/browser_automation_qc.txt}"
run_dir="tmp/llm_eval_runs"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_file="$run_dir/qwen_browser_automation_qc_$timestamp.json"
tmp_output_file="$output_file.tmp"
timeout_duration="${QWEN_QC_TIMEOUT:-180s}"

mkdir -p "$run_dir"

set +e
timeout "$timeout_duration" qwen --output-format json -p "$(cat "$prompt_file")" | tee "$tmp_output_file"
qwen_status="${PIPESTATUS[0]}"
set -e

if [[ "$qwen_status" -eq 0 ]]; then
  mv "$tmp_output_file" "$output_file"
  printf '\nSaved Qwen Code output to %s\n' "$output_file" >&2
else
  if [[ -s "$tmp_output_file" ]]; then
    mv "$tmp_output_file" "$output_file"
    printf '\nQwen Code failed; partial output saved to %s\n' "$output_file" >&2
  else
    printf '\nQwen Code failed before writing output.\n' >&2
  fi

  if [[ "$qwen_status" -eq 124 ]]; then
    printf 'Timed out after %s. Override with QWEN_QC_TIMEOUT=300s if needed.\n' "$timeout_duration" >&2
  fi

  exit "$qwen_status"
fi
