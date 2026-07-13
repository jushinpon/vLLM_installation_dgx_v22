#!/usr/bin/env bash
set -u

LOCK_FILE="/run/vllm_qwen35b_watchdog.lock"
LOG_FILE="/var/log/vllm_qwen35b_watchdog.log"
STATE_DIR="/var/lib/vllm_qwen35b_watchdog"
FAIL_FILE="$STATE_DIR/fail_count"
LAST_RESTART_FILE="$STATE_DIR/last_restart_epoch"

SETUP_DIR="/home/dgx-spark-vllm-setup-v022"
MANAGER="$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl"
BACKEND_HOST="node13"
BACKEND_PORT="8000"
MODEL_ID="/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8"
SERVED_MODEL="qwen3.6-35b-a3b-fp8"

FAIL_THRESHOLD=5
RESTART_COOLDOWN_SEC=900
PROBE_TIMEOUT_SEC=35
RESTART_TIMEOUT_SEC=1200

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >> "$LOG_FILE"
}

read_int_file() {
  local f="$1"
  if [ -f "$f" ]; then
    tr -cd '0-9' < "$f"
  else
    printf '0'
  fi
}

probe_backend_generation() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$BACKEND_HOST" \
    BACKEND_PORT="$BACKEND_PORT" SERVED_MODEL="$SERVED_MODEL" PROBE_TIMEOUT_SEC="$PROBE_TIMEOUT_SEC" \
    'python3 - <<'"'"'PY'"'"'
import json
import os
import sys
import time
import urllib.request

port = os.environ.get("BACKEND_PORT", "8000")
model = os.environ.get("SERVED_MODEL", "qwen3.6-35b-a3b-fp8")
timeout = int(os.environ.get("PROBE_TIMEOUT_SEC", "35"))
base = f"http://127.0.0.1:{port}"

def fail(msg):
    print("PROBE_FAIL", msg)
    sys.exit(1)

try:
    t0 = time.time()
    with urllib.request.urlopen(base + "/health", timeout=8) as r:
        if r.status != 200:
            fail(f"health_http={r.status}")

    with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
        data = json.loads(r.read().decode("utf-8", "replace"))
    model_ids = [m.get("id", "") for m in data.get("data", [])]
    if model not in model_ids:
        fail("model_not_listed=" + ",".join(model_ids))

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply exactly with: OK"}],
        "max_tokens": 8,
        "temperature": 0,
        "stream": False,
    }
    req = urllib.request.Request(
        base + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode("utf-8", "replace"))
    content = body["choices"][0]["message"].get("content", "").strip()
    if "OK" not in content.upper():
        fail("unexpected_content=" + content[:120])

    print("PROBE_OK elapsed_sec=%.2f content=%s" % (time.time() - t0, content[:120]))
    sys.exit(0)
except Exception as e:
    fail(type(e).__name__ + ": " + str(e))
PY'
}

restart_backend() {
  if [ ! -f "$MANAGER" ]; then
    log "RESTART_ABORT manager_not_found path=$MANAGER"
    return 1
  fi

  log "RESTART_BEGIN backend=$BACKEND_HOST:$BACKEND_PORT model=$SERVED_MODEL max_model_len=262144 text_only=1"
  (
    cd "$SETUP_DIR" &&
    timeout "$RESTART_TIMEOUT_SEC" perl "$MANAGER" backend-restart \
      --backend-host="$BACKEND_HOST" \
      --backend-port="$BACKEND_PORT" \
      --model-id="$MODEL_ID" \
      --served-model-name="$SERVED_MODEL" \
      --gpu-memory-utilization=0.85 \
      --max-model-len=262144 \
      --max-num-batched-tokens=16384 \
      --max-num-seqs=4 \
      --tool-call-parser=qwen3_coder \
      --reasoning-parser=qwen3 \
      --disable-thinking
  ) >> "$LOG_FILE" 2>&1
  local rc=$?
  date +%s > "$LAST_RESTART_FILE"
  if [ "$rc" -eq 0 ]; then
    echo 0 > "$FAIL_FILE"
    log "RESTART_OK"
  else
    log "RESTART_FAIL rc=$rc"
  fi
  return "$rc"
}

probe_output="$(probe_backend_generation 2>&1)"
probe_rc=$?

if [ "$probe_rc" -eq 0 ]; then
  echo 0 > "$FAIL_FILE"
  log "$probe_output"
  exit 0
fi

fail_count="$(read_int_file "$FAIL_FILE")"
fail_count="${fail_count:-0}"
fail_count=$((fail_count + 1))
echo "$fail_count" > "$FAIL_FILE"
log "PROBE_FAIL count=$fail_count/$FAIL_THRESHOLD detail=$probe_output"

if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
  exit 0
fi

now="$(date +%s)"
last_restart="$(read_int_file "$LAST_RESTART_FILE")"
last_restart="${last_restart:-0}"
since_restart=$((now - last_restart))

if [ "$last_restart" -gt 0 ] && [ "$since_restart" -lt "$RESTART_COOLDOWN_SEC" ]; then
  log "RESTART_SKIPPED cooldown_active seconds_since_restart=$since_restart cooldown=$RESTART_COOLDOWN_SEC"
  exit 0
fi

restart_backend
exit $?
