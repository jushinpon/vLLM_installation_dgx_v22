#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Restart only the node13 vLLM backend through the existing manager.
#   This keeps nginx/student-token configuration untouched.
#
# Run on:
#   cluster195 master node, as root.

cd /home/dgx-spark-vllm-setup-v022
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
  --disable-thinking
