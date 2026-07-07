#!/bin/bash
set -euo pipefail
BASE=/home/dgx-spark-vllm-setup-v022
DEPLOY="$BASE/deploy_vllm4dgx_v022_qwen35b.pl"
OUT="$BASE/nemotron_param_sweep_results.csv"
LOG="$BASE/nemotron_param_sweep.log"
API_KEY="070279fe547d73e6e8506b26afe9bb1f96f9bf26613c46cf01c26fecfd9a9098"
BACKEND="${BACKEND:-http://192.168.0.XX:8000/v1}"
MODEL_PATH=/local_opt/vllm-models/nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8
SERVED=nemotron-30b-moe-fp8
COMMON=(--model-id="$MODEL_PATH" --served-model-name="$SERVED" --startup-timeout=2400 --clear-reasoning-parser --clear-tool-call-parser --no-auto-tool-choice)

echo "label,gpu_mem,max_seqs,max_len,max_batched,prefix,chunked,eager,tok_s_1,tok_s_2,tok_s_3,median_tok_s,lat_1,lat_2,lat_3,comp_1,comp_2,comp_3,error" > "$OUT"
echo "=== Nemotron parameter sweep started $(date) ===" > "$LOG"

json_get_tokens() {
  python3 - "$1" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get('usage',{}).get('completion_tokens',0))
except Exception:
    print(0)
PY
}
median3(){ printf "%s\n%s\n%s\n" "$1" "$2" "$3" | sort -n | sed -n '2p'; }
wait_backend(){
  local start=$(date +%s)
  for _ in $(seq 1 240); do
    if curl -s --max-time 5 "$BACKEND/models" 2>/dev/null | grep -q "$SERVED"; then
      echo $(( $(date +%s) - start )); return 0
    fi
    sleep 5
  done
  echo 0; return 1
}
bench_once(){
  local tmpf=$(mktemp) start end elapsed comp rate
  start=$(date +%s.%N)
  curl -sS --max-time 240 -X POST "$BACKEND/chat/completions" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\":\"$SERVED\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain attention mechanisms in transformers. Focus on key-value-query attention, multi-head attention, and why scaling is needed.\"}],\"max_tokens\":512,\"temperature\":0.0}" > "$tmpf" 2>> "$LOG" || true
  end=$(date +%s.%N)
  elapsed=$(echo "$end - $start" | bc -l 2>/dev/null || echo 0)
  comp=$(json_get_tokens "$tmpf")
  rate=0
  if [ "$comp" -gt 0 ] && [ "$(echo "$elapsed > 0" | bc -l 2>/dev/null)" = "1" ]; then
    rate=$(echo "scale=2; $comp / $elapsed" | bc -l)
  else
    echo "BAD_RESPONSE $(head -c 400 < "$tmpf")" >> "$LOG"
  fi
  rm -f "$tmpf"
  echo "$rate,$elapsed,$comp"
}
run_cfg(){
  local label="$1" gpu="$2" seqs="$3" len="$4" batched="$5" prefix="$6" chunked="$7" eager="$8"
  echo "=== [$label] gpu=$gpu seqs=$seqs len=$len batched=$batched prefix=$prefix chunked=$chunked eager=$eager $(date) ===" | tee -a "$LOG"
  local args=("${COMMON[@]}" --gpu-memory-utilization="$gpu" --max-num-seqs="$seqs" --max-model-len="$len" --max-num-batched-tokens="$batched")
  [ "$prefix" = "0" ] && args+=(--no-prefix-caching)
  [ "$chunked" = "0" ] && args+=(--no-chunked-prefill)
  [ "$eager" = "1" ] && args+=(--force-eager)
  set +e
  ssh -o StrictHostKeyChecking=no node13 perl "$DEPLOY" restart "${args[@]}" >> "$LOG" 2>&1
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "$label,$gpu,$seqs,$len,$batched,$prefix,$chunked,$eager,0,0,0,0,0,0,0,0,0,0,deploy_rc_$rc" >> "$OUT"
    return 0
  fi
  wait_backend >> "$LOG"
  # warmup
  curl -sS --max-time 180 -X POST "$BACKEND/chat/completions" -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d "{\"model\":\"$SERVED\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello.\"}],\"max_tokens\":64,\"temperature\":0.0}" >/dev/null 2>&1 || true
  sleep 5
  local r1 r2 r3 t1 t2 t3 e1 e2 e3 c1 c2 c3 med
  r1=$(bench_once); IFS=, read -r t1 e1 c1 <<< "$r1"
  r2=$(bench_once); IFS=, read -r t2 e2 c2 <<< "$r2"
  r3=$(bench_once); IFS=, read -r t3 e3 c3 <<< "$r3"
  med=$(median3 "$t1" "$t2" "$t3")
  echo "$label,$gpu,$seqs,$len,$batched,$prefix,$chunked,$eager,$t1,$t2,$t3,$med,$e1,$e2,$e3,$c1,$c2,$c3," >> "$OUT"
  echo "=== [$label] median=$med tok/s ===" | tee -a "$LOG"
}

# Practical sweep: high-probability settings only. Each restart is expensive.
CONFIGS=(
  "baseline,0.70,16,32768,8192,1,1,0"
  "chunked_off,0.70,16,32768,8192,1,0,0"
  "prefix_off,0.70,16,32768,8192,0,1,0"
  "both_cache_off,0.70,16,32768,8192,0,0,0"
  "gpu075_chunked_off,0.75,16,32768,8192,1,0,0"
  "gpu080_chunked_off,0.80,16,32768,8192,1,0,0"
  "seq8_chunked_off,0.70,8,32768,8192,1,0,0"
  "seq32_chunked_off,0.70,32,32768,8192,1,0,0"
  "btok4096_chunked_off,0.70,16,32768,4096,1,0,0"
  "btok16384_chunked_off,0.70,16,32768,16384,1,0,0"
  "len16384_chunked_off,0.70,16,16384,8192,1,0,0"
  "len8192_chunked_off,0.70,16,8192,8192,1,0,0"
  "best_combo_guess,0.80,8,8192,4096,1,0,0"
  "eager_check,0.70,16,32768,8192,1,0,1"
)
for cfg in "${CONFIGS[@]}"; do
  IFS=, read -r label gpu seqs len batched prefix chunked eager <<< "$cfg"
  run_cfg "$label" "$gpu" "$seqs" "$len" "$batched" "$prefix" "$chunked" "$eager"
done

echo "=== Nemotron parameter sweep finished $(date) ===" | tee -a "$LOG"
