#!/usr/bin/env bash
set -euo pipefail

cmd=$(pgrep -af 'vllm.entrypoints.openai.api_server' | head -n 1 || true)
[[ -n "$cmd" ]] || { echo 'FAIL: vLLM API server process is absent' >&2; exit 1; }

for expected in \
    '--gpu-memory-utilization 0.85' \
    '--max-model-len 131072' \
    '--max-num-batched-tokens 16384' \
    '--max-num-seqs 10' \
    '--kv-cache-dtype fp8' \
    '--limit-mm-per-prompt {"image":4}' \
    '--performance-mode throughput' \
    '--optimization-level 2'; do
    [[ "$cmd" == *"$expected"* ]] || { echo "FAIL: missing process option: $expected" >&2; echo "$cmd" >&2; exit 1; }
done

[[ "$cmd" != *'--language-model-only'* ]] || { echo 'FAIL: text-only mode is enabled' >&2; echo "$cmd" >&2; exit 1; }

for expected in \
    '--spec-method dflash' \
    '--spec-model /local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2' \
    '--spec-tokens 7'; do
    [[ "$cmd" == *"$expected"* ]] || { echo "FAIL: missing DFlash option: $expected" >&2; echo "$cmd" >&2; exit 1; }
done

models=$(curl -fsS --max-time 15 http://127.0.0.1:8000/v1/models)
[[ "$models" == *'mel_llm'* ]] || { echo 'FAIL: mel_llm is not served' >&2; exit 1; }

payload='{"model":"mel_llm","messages":[{"role":"user","content":"Reply with OK"}],"max_tokens":2,"temperature":0}'
reply=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' \
    -d "$payload" http://127.0.0.1:8000/v1/chat/completions)
[[ "$reply" == *'"finish_reason":"stop"'* ]] || { echo 'FAIL: chat completion did not stop normally' >&2; exit 1; }

echo 'PASS: multimodal vLLM profile, model endpoint, and chat endpoint'
