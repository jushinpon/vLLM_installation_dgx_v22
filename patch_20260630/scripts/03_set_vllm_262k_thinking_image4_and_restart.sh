#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Persist the preferred vLLM manager defaults:
#   - max_model_len = 262144
#   - thinking enabled through default chat template kwargs
#   - multimodal enabled with image limit 4
#   Then restart only the node13 backend.
#
# Run on:
#   cluster195 master node, as root.

SETUP_DIR="/home/vLLM_installation_dgx_v22"
MANAGER="$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl"
BACKUP_DIR="/root/codex_backups_vllm/$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$MANAGER" "$BACKUP_DIR/"

echo "===BACKUP==="
echo "$BACKUP_DIR/$(basename "$MANAGER")"

python3 - <<'PY2'
from pathlib import Path
import re
p = Path("/home/vLLM_installation_dgx_v22/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl")
s = p.read_text()
s = re.sub(r"max_model_len\s*=>\s*'[^']*'", "max_model_len          => '262144'", s)
s = re.sub(r"disable_thinking\s*=>\s*[01]", "disable_thinking       => 0", s)
s = re.sub(r"default_chat_template_kwargs\s*=>\s*'[^']*'", "default_chat_template_kwargs => '{\"enable_thinking\": true}'", s)
s = re.sub(r"language_model_only\s*=>\s*[01]", "language_model_only    => 0", s)
s = re.sub(r"limit_mm_per_prompt\s*=>\s*'[^']*'", "limit_mm_per_prompt    => '{\"image\":4}'", s)
p.write_text(s)
PY2

grep -nE "max_model_len|max_num_batched_tokens|disable_thinking|default_chat_template_kwargs|language_model_only|limit_mm_per_prompt" "$MANAGER" | head -60

cd "$SETUP_DIR"
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --backend-port=8000 \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
  --served-model-name=qwen3.6-35b-a3b-fp8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=262144 \
  --max-num-batched-tokens=16384 \
  --max-num-seqs=4 \
  --tool-call-parser=qwen3_coder \
  --reasoning-parser=qwen3 \
  --default-chat-template-kwargs='{"enable_thinking": true}' \
  --no-language-model-only \
  --limit-mm-per-prompt='{"image":4}'
