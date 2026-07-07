#!/bin/bash
set -euo pipefail

BASE=/home/dgx-spark-vllm-setup-v022
DEPLOY="$BASE/deploy_vllm4dgx_v022_qwen35b.pl"
OUT="$BASE/model_benchmark_results.csv"
LOG="$BASE/model_benchmark_run.log"
API_KEY="${VLLM_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  echo "Set VLLM_API_KEY before running benchmarks." >&2
  exit 1
fi
BACKEND="${BACKEND:-http://192.168.0.XX:8000/v1}"
COMMON_ARGS=(--gpu-memory-utilization=0.70 --max-num-seqs=16 --max-model-len=32768 --max-num-batched-tokens=8192 --startup-timeout=2400 --no-chunked-prefill)

echo "model_label,served_model,model_path,start_status,ready_secs,tok_s_1,tok_s_2,tok_s_3,median_tok_s,latency_1,latency_2,latency_3,completion_tokens_1,completion_tokens_2,completion_tokens_3,error" > "$OUT"
echo "=== Model benchmark started $(date) ===" > "$LOG"

json_get_tokens() {
  python3 - "$1" <<'PYEOF'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get('usage',{}).get('completion_tokens',0))
except Exception:
    print(0)
PYEOF
}

median3() { printf "%s\n%s\n%s\n" "$1" "$2" "$3" | sort -n | sed -n '2p'; }

wait_backend() {
  local model="$1"
  local start
  start=$(date +%s)
  for _ in $(seq 1 240); do
    if curl -sS --max-time 5 -H "Authorization: Bearer $API_KEY" "$BACKEND/models" 2>/dev/null | grep -q "$model"; then
      local end
      end=$(date +%s)
      echo $((end-start))
      return 0
    fi
    sleep 5
  done
  echo 0
  return 1
}

bench_model() {
  local label="$1" served="$2" path="$3" parser_mode="$4"
  echo "=== [$label] start $(date) ===" | tee -a "$LOG"
  local extra_args=()
  if [ "$parser_mode" = "qwen" ]; then
    extra_args=(--disable-thinking)
  else
    extra_args=(--clear-reasoning-parser --clear-tool-call-parser --no-auto-tool-choice)
  fi

  set +e
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 node13 \
    perl "$DEPLOY" restart --model-id="$path" --served-model-name="$served" "${COMMON_ARGS[@]}" "${extra_args[@]}" >> "$LOG" 2>&1
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "$label,$served,$path,start_failed,0,0,0,0,0,0,0,0,0,0,0,deploy_rc_$rc" >> "$OUT"
    echo "=== [$label] deploy failed rc=$rc ===" | tee -a "$LOG"
    return 0
  fi

  local ready_secs
  if ! ready_secs=$(wait_backend "$served"); then
    echo "$label,$served,$path,not_ready,$ready_secs,0,0,0,0,0,0,0,0,0,0,not_ready" >> "$OUT"
    echo "=== [$label] not ready ===" | tee -a "$LOG"
    return 0
  fi
  echo "[$label] ready in ${ready_secs}s" | tee -a "$LOG"

  curl -sS --max-time 180 -X POST "$BACKEND/chat/completions" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\":\"$served\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello.\"}],\"max_tokens\":64,\"temperature\":0.2}" >/dev/null 2>&1 || true
  sleep 5

  local t1=0 t2=0 t3=0 e1=0 e2=0 e3=0 c1=0 c2=0 c3=0
  for i in 1 2 3; do
    local tmpf
    tmpf=$(mktemp)
    local s
    s=$(date +%s.%N)
    curl -sS --max-time 240 -X POST "$BACKEND/chat/completions" \
      -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
      -d "{\"model\":\"$served\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain attention mechanisms in transformers.\"}],\"max_tokens\":512,\"temperature\":0.2}" > "$tmpf" 2>> "$LOG" || true
    local f
    f=$(date +%s.%N)
    local elapsed
    elapsed=$(echo "$f - $s" | bc -l 2>/dev/null || echo 0)
    local comp
    comp=$(json_get_tokens "$tmpf")
    local rate=0
    if [ "$comp" -gt 0 ] && [ "$(echo "$elapsed > 0" | bc -l 2>/dev/null)" = "1" ]; then
      rate=$(echo "scale=2; $comp / $elapsed" | bc -l)
    else
      python3 - "$tmpf" "$label" "$i" >> "$LOG" <<'PYEOF'
import sys
path,label,i=sys.argv[1],sys.argv[2],sys.argv[3]
print(f'[{label}] iteration {i} bad response: ' + open(path, errors='replace').read()[:300])
PYEOF
    fi
    rm -f "$tmpf"
    case $i in
      1) t1=$rate; e1=$elapsed; c1=$comp;;
      2) t2=$rate; e2=$elapsed; c2=$comp;;
      3) t3=$rate; e3=$elapsed; c3=$comp;;
    esac
  done
  local med
  med=$(median3 "$t1" "$t2" "$t3")
  echo "$label,$served,$path,ok,$ready_secs,$t1,$t2,$t3,$med,$e1,$e2,$e3,$c1,$c2,$c3," >> "$OUT"
  echo "=== [$label] done median=${med} tok/s ===" | tee -a "$LOG"
}

bench_model "Llama-3.1-8B-FP8" "llama-3.1-8b-fp8" "/local_opt/vllm-models/nvidia-Llama-3.1-8B-Instruct-FP8" "plain"
bench_model "Qwen3-14B-FP8" "qwen3-14b-fp8" "/local_opt/vllm-models/nvidia-Qwen3-14B-FP8" "qwen"
bench_model "Qwen3-32B-NVFP4" "qwen3-32b-nvfp4" "/local_opt/vllm-models/nvidia-Qwen3-32B-NVFP4" "qwen"
bench_model "Nemotron-30B-MoE-FP8" "nemotron-30b-moe-fp8" "/local_opt/vllm-models/nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8" "plain"
bench_model "Phi-4-reasoning-plus-FP8" "phi-4-reasoning-plus-fp8" "/local_opt/vllm-models/nvidia-Phi-4-reasoning-plus-FP8" "plain"

echo "=== Model benchmark finished $(date) ===" | tee -a "$LOG"
ssh -o StrictHostKeyChecking=no node13 \
  perl "$DEPLOY" restart --model-id="/local_opt/vllm-models/nvidia-Qwen3-14B-FP8" --served-model-name="qwen3-14b-fp8" "${COMMON_ARGS[@]}" --disable-thinking >> "$LOG" 2>&1 || true
