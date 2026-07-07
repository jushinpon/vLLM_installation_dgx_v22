#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Persist safer vLLM manager defaults:
#   - max_model_len = 131072
#   - text-only mode
#   - no image/multimodal prompt limit
#   Then restart only the node13 backend.
#
# Run on:
#   cluster195 master node, as root.

SETUP_DIR="/home/dgx-spark-vllm-setup-v022"
MANAGER="$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl"
BACKUP_DIR="/root/codex_backups_vllm/$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$MANAGER" "$BACKUP_DIR/"

echo "===BACKUP==="
echo "$BACKUP_DIR/$(basename "$MANAGER")"

perl -0pi -e "s/max_model_len\\s*=>\\s*'\\d+'/max_model_len          => '131072'/g; s/max_num_batched_tokens\\s*=>\\s*'320000'/max_num_batched_tokens => '16384'/g; s/language_model_only\\s*=>\\s*0/language_model_only      => 1/g; s/limit_mm_per_prompt\\s*=>\\s*'\\{\"image\":1\\}'/limit_mm_per_prompt    => ''/g" "$MANAGER"

grep -nE "max_model_len|max_num_batched_tokens|language_model_only|limit_mm_per_prompt" "$MANAGER" | head -40

cd "$SETUP_DIR"
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --backend-port=8000 \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
  --served-model-name=qwen3.6-35b-a3b-fp8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=131072 \
  --max-num-batched-tokens=16384 \
  --max-num-seqs=4 \
  --tool-call-parser=qwen3_coder \
  --reasoning-parser=qwen3 \
  --disable-thinking
