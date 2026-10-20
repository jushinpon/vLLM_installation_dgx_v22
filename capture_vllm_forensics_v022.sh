#!/usr/bin/env bash
set -euo pipefail

# Capture state at the moment the watchdog detects a vLLM failure.  Do not add
# request bodies, Authorization headers, or other credentials to this bundle.

HOST_ROOT="/local_opt/vllm-service-qwen35b/hosts/$(hostname)"
FORENSICS_ROOT="$HOST_ROOT/forensics"
LOG_FILE="$HOST_ROOT/logs/vllm_server.log"
INCIDENT_ID=""

for arg in "$@"; do
  case "$arg" in
    --incident-id=*) INCIDENT_ID="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! "$INCIDENT_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "--incident-id must contain only letters, digits, dot, underscore, or dash" >&2
  exit 2
fi

umask 077
find "$FORENSICS_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +60 -exec rm -rf -- {} + 2>/dev/null || true
OUT="$FORENSICS_ROOT/$INCIDENT_ID"
mkdir -p "$OUT"

date --iso-8601=seconds > "$OUT/captured_at.txt"
hostnamectl > "$OUT/host.txt" 2>&1 || true
uptime > "$OUT/uptime.txt" 2>&1 || true
free -h > "$OUT/memory.txt" 2>&1 || true
ps -eo pid,ppid,user,etime,%cpu,%mem,args --sort=-%mem > "$OUT/processes.txt" 2>&1 || true
ss -ltnp > "$OUT/listening_sockets.txt" 2>&1 || true
nvidia-smi -L > "$OUT/gpu_devices.txt" 2>&1 || true
nvidia-smi --query-gpu=timestamp,name,driver_version,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,pstate --format=csv,noheader,nounits > "$OUT/gpu_summary.csv" 2>&1 || true
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader > "$OUT/gpu_processes.csv" 2>&1 || true
nvidia-smi -q > "$OUT/gpu_detail.txt" 2>&1 || true
journalctl -k --since '-30 minutes' --no-pager > "$OUT/kernel_last_30m.txt" 2>&1 || true
journalctl --since '-30 minutes' --no-pager > "$OUT/system_last_30m.txt" 2>&1 || true
tail -n 1200 "$LOG_FILE" > "$OUT/vllm_server_tail.log" 2>&1 || true

printf 'incident_id=%s\nlog_file=%s\n' "$INCIDENT_ID" "$LOG_FILE" > "$OUT/manifest.txt"
echo "$OUT"
