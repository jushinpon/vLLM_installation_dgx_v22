#!/bin/bash
set -euo pipefail
BASE=/home/dgx-spark-vllm-setup-v022
DEPLOY="$BASE/deploy_vllm4dgx_v022_qwen35b.pl"
OUT="$BASE/opencode_quality_ab_results.jsonl"
LOG="$BASE/opencode_quality_ab_run.log"
API_KEY="070279fe547d73e6e8506b26afe9bb1f96f9bf26613c46cf01c26fecfd9a9098"
BACKEND=http://192.168.0.14:8000/v1
COMMON=(--gpu-memory-utilization=0.70 --max-num-seqs=16 --max-model-len=32768 --max-num-batched-tokens=8192 --startup-timeout=2400 --no-chunked-prefill)
: > "$OUT"
echo "=== opencode quality A/B started $(date) ===" > "$LOG"
wait_model(){ local m="$1"; for _ in $(seq 1 240); do curl -s --max-time 5 "$BACKEND/models" | grep -q "$m" && return 0; sleep 5; done; return 1; }
run_prompt(){ local label="$1" served="$2" task_id="$3" prompt="$4"; python3 - "$OUT" "$label" "$served" "$task_id" "$prompt" <<'PY'
import json, sys, time, urllib.request
out,label,model,task_id,prompt=sys.argv[1:]
body={"model":model,"messages":[{"role":"system","content":"You are an expert coding agent. Answer concisely but show enough reasoning to be auditable. Do not use tools."},{"role":"user","content":prompt}],"max_tokens":900,"temperature":0.0}
data=json.dumps(body).encode()
req=urllib.request.Request('http://192.168.0.14:8000/v1/chat/completions',data=data,headers={'Content-Type':'application/json','Authorization':'Bearer 070279fe547d73e6e8506b26afe9bb1f96f9bf26613c46cf01c26fecfd9a9098'})
t0=time.time()
try:
    resp=json.loads(urllib.request.urlopen(req, timeout=240).read().decode())
    dt=time.time()-t0
    ch=resp['choices'][0]['message']
    rec={"label":label,"model":model,"task_id":task_id,"latency":round(dt,2),"usage":resp.get('usage',{}),"content":ch.get('content',''),"reasoning":ch.get('reasoning',''),"error":""}
except Exception as e:
    rec={"label":label,"model":model,"task_id":task_id,"latency":0,"usage":{},"content":"","reasoning":"","error":repr(e)}
with open(out,'a') as f: f.write(json.dumps(rec,ensure_ascii=False)+"\n")
print(json.dumps({k:rec[k] for k in ['label','task_id','latency','error']},ensure_ascii=False))
PY
}
bench_model(){ local label="$1" served="$2" path="$3" mode="$4"; shift 4; local extra=("$@"); echo "=== [$label] restart $(date) ===" | tee -a "$LOG"; ssh -o StrictHostKeyChecking=no node13 perl "$DEPLOY" restart --model-id="$path" --served-model-name="$served" "${COMMON[@]}" "${extra[@]}" >> "$LOG" 2>&1; wait_model "$served"; sleep 5; echo "=== [$label] prompts ===" | tee -a "$LOG"; run_prompt "$label" "$served" bugfix 'A Python function is intended to return the first duplicate integer in a list, preserving input order. It currently returns the first value whose count becomes 2, but it fails for unhashable values and for NaN. Provide a robust implementation and explain edge cases briefly.'; run_prompt "$label" "$served" repo_plan 'You are given a codebase where HTTP handlers directly query SQL and duplicate auth checks. Propose a minimal refactor plan that reduces duplication without changing behavior. Include risk controls and verification steps.'; run_prompt "$label" "$served" logic 'Solve carefully: We have three services A, B, C. A calls B twice; B calls C three times per call. C has p95 latency 40ms but 1% timeout at 2s. Requests are sequential within each service. What dominates A p95 and what change would you try first?'; }
bench_model 'Qwen3.6-35B-A3B-FP8-thinking-on' 'qwen3.6-35b-a3b-fp8' '/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8' qwen --enable-thinking
bench_model 'Nemotron-30B-MoE-FP8' 'nemotron-30b-moe-fp8' '/local_opt/vllm-models/nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8' plain --clear-reasoning-parser --clear-tool-call-parser --no-auto-tool-choice
bench_model 'Qwen3-32B-NVFP4' 'qwen3-32b-nvfp4' '/local_opt/vllm-models/nvidia-Qwen3-32B-NVFP4' qwen --enable-thinking
bench_model 'Qwen3-14B-FP8' 'qwen3-14b-fp8' '/local_opt/vllm-models/nvidia-Qwen3-14B-FP8' qwen --enable-thinking
echo "=== opencode quality A/B finished $(date) ===" | tee -a "$LOG"
