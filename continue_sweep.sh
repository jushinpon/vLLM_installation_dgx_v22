#!/bin/bash
set -euo pipefail

BASE_DIR=/home/dgx-spark-vllm-setup-v022
MANAGE="$BASE_DIR/manage_lab_vllm_from_master_v022_qwen35b.pl"
CSV="$BASE_DIR/sweep_results.csv"
API_KEY="070279fe547d73e6e8506b26afe9bb1f96f9bf26613c46cf01c26fecfd9a9098"
BACKEND_IP="192.168.0.14"
SETUP_DIR_OPT="--backend-setup-dir=/home/dgx-spark-vllm-setup-v022"

# Python parser
py_script="/tmp/parse_bench.py"
cat > "$py_script" << 'PYEOF'
import sys, json
f = sys.argv[1]
d = json.load(open(f))
print(d.get("usage", {}).get("completion_tokens", 0))
PYEOF

bench_backend() {
    local label="$1"; shift
    local t1=0 t2=0 t3=0 e1=0 e2=0 e3=0 c1=0 c2=0 c3=0
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
    # Trim whitespace
    extra=$(echo "$extra" | xargs)
    echo ">> Start: gpu_mem=$gpu_mem seqs=$seqs len=$len batched=$batched eager=$eager chunked=$chunked"
    if [ -n "$extra" ]; then
        perl "$MANAGE" backend-start --backend-setup-dir=/home/dgx-spark-vllm-setup-v022 --gpu-memory-utilization=$gpu_mem --max-num-seqs=$seqs --max-model-len=$len --max-num-batched-tokens=$batched $SETUP_DIR_OPT $extra 2>&1 | tail -5
    else
        perl "$MANAGE" backend-start --backend-setup-dir=/home/dgx-spark-vllm-setup-v022 --gpu-memory-utilization=$gpu_mem --max-num-seqs=$seqs --max-model-len=$len --max-num-batched-tokens=$batched $SETUP_DIR_OPT 2>&1 | tail -5
    fi
}

do_stop() {
    echo "STOP OK"
    perl "$MANAGE" backend-stop $SETUP_DIR_OPT > /dev/null 2>&1 || true
}

echo "=== Continuation Sweep ==="
date

# Remaining configs:
for config in \
    "len=16384,0.70,16,16384,8192,0,1" \
    "len=65536,0.70,16,65536,8192,0,1" \
    "batched=4096,0.70,16,32768,4096,0,1" \
    "batched=16384,0.70,16,32768,16384,0,1" \
    "batched=32768,0.70,16,32768,32768,0,1" \
    "eager=1,0.70,16,32768,8192,1,1" \
    "chunked=0,0.70,16,32768,8192,0,0" \
    "best_combo,0.80,32,32768,8192,0,1"; do

    IFS=',' read -r label gpu_mem seqs len batched eager chunked <<< "$config"

    echo ">> Sleeping for JIT cooldown..."
    sleep 30

    do_stop; sleep 3
    do_start "$gpu_mem" "$seqs" "$len" "$batched" "$eager" "$chunked"

    # Wait for backend with TIMEOUT_RC=1
    if ! wait_backend; then
        echo "  SKIP - backend failed to start"
        continue
    fi

    # Warmup
    curl -s --max-time 180 -X POST "http://${BACKEND_IP}:8000/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d '{"model":"qwen3.6-35b-a3b-fp8","messages":[{"role":"user","content":"Hello."}],"max_tokens":64,"temperature":0.2,"extra_body":{"chat_template_kwargs":{"enable_thinking":false}}}' > /dev/null 2>&1
    sleep 5

    bench_backend "$label" "$gpu_mem" "$seqs" "$len" "$batched" "$eager" "$chunked"
done

echo "=== SWEEP CONTINUATION DONE ==="
date
