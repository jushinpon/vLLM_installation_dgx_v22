#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Read-only check of the live node13 vLLM configuration.
#
# Run on:
#   cluster195 master node, as root.

ssh -o BatchMode=yes -o ConnectTimeout=8 node13 'bash -s' <<'NODE13'
echo "===MODELS==="
curl -sS -m 10 http://127.0.0.1:8000/v1/models | python3 -c 'import sys,json; d=json.load(sys.stdin); m=d["data"][0]; print(m["id"], m["max_model_len"])'
echo "===HEALTH==="
curl -sS -m 10 -o /dev/null -w 'health_http=%{http_code}\n' http://127.0.0.1:8000/health
echo "===RUNNING_VLLM_PROCESS==="
ps -eo pid,args | grep -E 'vllm.entrypoints.openai.api_server' | grep -v grep || true
NODE13
