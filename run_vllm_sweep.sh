#!/bin/bash
set -euo pipefail

BASE_DIR=/home/dgx-spark-vllm-setup-v022
MANAGE="$BASE_DIR/manage_lab_vllm_from_master_v022_qwen35b.pl"
CSV="$BASE_DIR/sweep_results.csv"
API_KEY="${VLLM_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  echo "Set VLLM_API_KEY before running this sweep." >&2
  exit 1
fi
BACKEND_IP="${BACKEND_IP:-192.168.0.XX}"
SETUP_DIR_OPT="--backend-setup-dir=/home/dgx-spark-vllm-setup-v022"

echo "run_label,gpu_mem,max_seqs,max_len,max_batched,eager,chunked,tok_s_1,tok_s_2,tok_s_3,median_tok_s,elapsed_secs,completion_tokens" > "$CSV"

bench_backend() {
    local label="$1"; shift
    local t1=0 t2=0 t3=0 e1=0 e2=0 e3=0 c1=0 c2=0 c3=0
    local py_script="/tmp/parse_bench.py"
    # Write Python parser once
    cat > "$py_script" << 'PYEOF'
import sys, json
f = sys.argv[1]
d = json.load(open(f))
print(d.get("usage", {}).get("completion_tokens", 0))
PYEOF
    for i in 1 2 3; do
        local start=$(date +%s.%N)
        local tmpf=$(mktemp)
        curl -sS --max-time 180 -X POST "http://${BACKEND_IP}:8000/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d '{"model":"qwen3.6-35b-a3b-fp8","messages":[{"role":"user","content":"Explain attention mechanisms in transformers."}],"max_tokens":512,"temperature":0.2,"extra_body":{"chat_template_kwargs":{"enable_thinking":false}}}' > "$tmpf" 2>/dev/null
        local end=$(date +%s.%N)
        local elapsed=$(echo "$end - $start" | bc -l 2>/dev/null || echo "0")
        local comp_tok=$(python3 "$py_script" "$tmpf" 2>/dev/null || echo "0")
        if [ "$comp_tok" = "0" ]; then
            echo "  [DEBUG] Iter $i: comp_tok=0, resp=$(head -c 200 < "$tmpf" 2>/dev/null)"
        fi
        rm -f "$tmpf"
        if [ "$comp_tok" -gt 0 ] && [ "$(echo "$elapsed > 0" | bc -l 2>/dev/null)" = "1" ]; then
            local tok_s=$(echo "scale=2; $comp_tok / $elapsed" | bc -l 2>/dev/null || echo "0")
        else
            local tok_s=0
        fi
        case $i in 1) t1=$tok_s; e1=$elapsed; c1=$comp_tok;; 2) t2=$tok_s; e2=$elapsed; c2=$comp_tok;; 3) t3=$tok_s; e3=$elapsed; c3=$comp_tok;; esac
    done
    local sorted=$(printf "%s\n" "$t1" "$t2" "$t3" | sort -n)
    local median=$(echo "$sorted" | sed -n '2p')
    echo "  Runs: $t1 $t2 $t3 tok/s | Median: $median"
    echo "$label,$1,$2,$3,$4,$5,$6,$t1,$t2,$t3,$median,$e1/$e2/$e3,$c1/$c2/$c3" >> "$CSV"
}

wait_backend() {
    echo "  Waiting for backend..."
    for i in $(seq 1 60); do
        if curl -s --max-time 5 "http://${BACKEND_IP}:8000/v1/models" > /dev/null 2>&1; then
            echo "  Ready after ${i}x5s"; sleep 5; return 0
        fi
        sleep 5
    done
    echo "  TIMEOUT"; return 1
}

do_start() {
    local gpu_mem=$1 seqs=$2 len=$3 batched=$4 eager=$5 chunked=$6
    local extra=""
    [ "$eager" = "1" ] && extra="$extra --force-eager"
    [ "$chunked" = "0" ] && extra="$extra --no-chunked-prefill"
    extra=$(echo "$extra" | xargs)
    echo ">> Start: gpu_mem=$gpu_mem seqs=$seqs len=$len batched=$batched eager=$eager chunked=$chunked"
    if [ -n "$extra" ]; then
        perl "$MANAGE" backend-start "$SETUP_DIR_OPT" --gpu-memory-utilization="$gpu_mem" --max-num-seqs="$seqs" --max-model-len="$len" --max-num-batched-tokens="$batched" --backend-extra-args="$extra" 2>&1 | tail -5
    else
        perl "$MANAGE" backend-start "$SETUP_DIR_OPT" --gpu-memory-utilization="$gpu_mem" --max-num-seqs="$seqs" --max-model-len="$len" --max-num-batched-tokens="$batched" 2>&1 | tail -5
    fi
}

do_stop() {
    perl "$MANAGE" backend-stop "$SETUP_DIR_OPT" 2>/dev/null || true
}

echo "=== vLLM Parameter Sweep - Qwen3.6-35B-A3B-FP8 ==="
echo "Start: $(date)"

do_stop; sleep 3

# 0. Baseline
do_start 0.70 16 32768 8192 0 1; wait_backend
# Warmup: one request to prime JIT caches
curl -s --max-time 180 -X POST "http://${BACKEND_IP}:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{"model":"qwen3.6-35b-a3b-fp8","messages":[{"role":"user","content":"Hello."}],"max_tokens":64,"temperature":0.2,"extra_body":{"chat_template_kwargs":{"enable_thinking":false}}}' > /dev/null 2>&1
sleep 5
bench_backend baseline 0.70 16 32768 8192 0 1

# 1. GPU Memory Utilization
for val in 0.65 0.75 0.80 0.85 0.90; do
    do_start "$val" 16 32768 8192 0 1; wait_backend
    bench_backend "gpu_mem=$val" "$val" 16 32768 8192 0 1
done

# 2. Max Num Sequences
for val in 8 32 64; do
    do_start 0.70 "$val" 32768 8192 0 1; wait_backend
    bench_backend "seqs=$val" 0.70 "$val" 32768 8192 0 1
done

# 3. Max Model Length
for val in 16384 65536; do
    do_start 0.70 16 "$val" 8192 0 1; wait_backend
    bench_backend "len=$val" 0.70 16 "$val" 8192 0 1
done

# 4. Max Batched Tokens
for val in 4096 16384 32768; do
    do_start 0.70 16 32768 "$val" 0 1; wait_backend
    bench_backend "batched=$val" 0.70 16 32768 "$val" 0 1
done

# 5. Enforce Eager
do_start 0.70 16 32768 8192 1 1; wait_backend
bench_backend eager1 0.70 16 32768 8192 1 1

# 6. Chunked Prefill off
do_start 0.70 16 32768 8192 0 0; wait_backend
bench_backend chunked0 0.70 16 32768 8192 0 0

# 7. Best combo: gpu_mem=0.80 + seqs=32
do_start 0.80 32 32768 8192 0 1; wait_backend
bench_backend best_combo 0.80 32 32768 8192 0 1

# Restore baseline
do_stop
echo "=== DONE: $(date) ==="
echo "Results: $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
