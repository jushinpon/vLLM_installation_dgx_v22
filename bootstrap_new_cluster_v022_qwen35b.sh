#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_HOST="node13"
BACKEND_USER="root"
BACKEND_TARGET_DIR="$REPO_DIR"
INSTALL_DIR="/local_opt/vllm-install"
MODEL_PRESET="qwen36_35b_a3b_fp8"
MODEL_ID="/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8"
SERVED_MODEL_NAME="qwen3.6-35b-a3b-fp8"
GATEWAY_PORT="9000"
BACKEND_PORT="8000"
GPU_MEMORY_UTILIZATION="0.85"
MAX_MODEL_LEN="262144"
MAX_NUM_SEQS="4"
MAX_NUM_BATCHED_TOKENS="16384"
RPM_LIMIT="120"
MAX_CONCURRENT_PER_STUDENT="6"
CLIENT_TIMEOUT="300"
DOWNSTREAM_TIMEOUT="600"
REQUEST_HARD_TIMEOUT="900"
MAX_CHILDREN="96"
MODE=""
WITH_CLEANUP="0"
WITH_WATCHDOG="1"
FORCE_CLEAN_INSTALL="0"
SKIP_MODEL_DOWNLOAD="0"
DRY_RUN="0"

usage() {
  cat <<'USAGE'
Usage:
  bash bootstrap_new_cluster_v022_qwen35b.sh --full-install [options]
  bash bootstrap_new_cluster_v022_qwen35b.sh --apply-only [options]

Modes:
  --full-install       Copy repo to backend, install vLLM, download model, deploy backend+gateway, install watchdog.
  --apply-only         Deploy/restart backend+gateway from an already prepared backend/model.

Common options:
  --backend-host HOST          Backend node hostname (default: node13)
  --backend-user USER          SSH user for backend (default: root)
  --backend-target-dir DIR     Repo copy path on backend (default: same path as master repo)
  --install-dir DIR            vLLM install root (default: /local_opt/vllm-install)
  --model-preset NAME          download_model preset (default: qwen36_35b_a3b_fp8)
  --model-id PATH              Local model path passed to vLLM
  --served-model-name NAME     OpenAI model name
  --gateway-port PORT          Master nginx gateway port (default: 9000)
  --backend-port PORT          Backend vLLM port (default: 8000)
  --gpu-memory-utilization N   vLLM GPU memory utilization (default: 0.85)
  --max-model-len N            vLLM max context length (default: 262144)
  --max-num-seqs N             vLLM max concurrent sequences (default: 4)
  --max-num-batched-tokens N   vLLM max batched tokens (default: 16384)
  --rpm-limit N                Gateway per-token request limit (default: 120)
  --max-concurrent N           Gateway per-student concurrency (default: 6)
  --with-cleanup               Run master cleanup before deployment
  --no-watchdog                Do not install watchdog
  --skip-model-download        Skip download_model step in --full-install
  --force-clean-install        Pass --force-clean to install_vllm-v022.sh on backend
  --dry-run                    Print commands without running
  -h, --help                   Show this help

Example:
  bash bootstrap_new_cluster_v022_qwen35b.sh --full-install --backend-host=node13
USAGE
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quote_args() {
  local out=()
  local arg
  for arg in "$@"; do
    out+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${out[*]}"
}

run() {
  log "+ $(quote_args "$@")"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

run_shell() {
  log "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  bash -lc "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-install) MODE="full-install"; shift ;;
    --apply-only) MODE="apply-only"; shift ;;
    --backend-host=*) BACKEND_HOST="${1#*=}"; shift ;;
    --backend-host) BACKEND_HOST="$2"; shift 2 ;;
    --backend-user=*) BACKEND_USER="${1#*=}"; shift ;;
    --backend-user) BACKEND_USER="$2"; shift 2 ;;
    --backend-target-dir=*) BACKEND_TARGET_DIR="${1#*=}"; shift ;;
    --backend-target-dir) BACKEND_TARGET_DIR="$2"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --model-preset=*) MODEL_PRESET="${1#*=}"; shift ;;
    --model-preset) MODEL_PRESET="$2"; shift 2 ;;
    --model-id=*) MODEL_ID="${1#*=}"; shift ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --served-model-name=*) SERVED_MODEL_NAME="${1#*=}"; shift ;;
    --served-model-name) SERVED_MODEL_NAME="$2"; shift 2 ;;
    --gateway-port=*) GATEWAY_PORT="${1#*=}"; shift ;;
    --gateway-port) GATEWAY_PORT="$2"; shift 2 ;;
    --backend-port=*) BACKEND_PORT="${1#*=}"; shift ;;
    --backend-port) BACKEND_PORT="$2"; shift 2 ;;
    --gpu-memory-utilization=*) GPU_MEMORY_UTILIZATION="${1#*=}"; shift ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION="$2"; shift 2 ;;
    --max-model-len=*) MAX_MODEL_LEN="${1#*=}"; shift ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --max-num-seqs=*) MAX_NUM_SEQS="${1#*=}"; shift ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --max-num-batched-tokens=*) MAX_NUM_BATCHED_TOKENS="${1#*=}"; shift ;;
    --max-num-batched-tokens) MAX_NUM_BATCHED_TOKENS="$2"; shift 2 ;;
    --rpm-limit=*) RPM_LIMIT="${1#*=}"; shift ;;
    --rpm-limit) RPM_LIMIT="$2"; shift 2 ;;
    --max-concurrent=*) MAX_CONCURRENT_PER_STUDENT="${1#*=}"; shift ;;
    --max-concurrent) MAX_CONCURRENT_PER_STUDENT="$2"; shift 2 ;;
    --with-cleanup) WITH_CLEANUP="1"; shift ;;
    --no-watchdog) WITH_WATCHDOG="0"; shift ;;
    --skip-model-download) SKIP_MODEL_DOWNLOAD="1"; shift ;;
    --force-clean-install) FORCE_CLEAN_INSTALL="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$MODE" ]] || { usage; die "Choose --full-install or --apply-only"; }
[[ -d "$REPO_DIR/.git" ]] || die "Run this script from a cloned repo directory"

BACKEND_SSH="${BACKEND_USER}@${BACKEND_HOST}"
MANAGER="$REPO_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl"
[[ -f "$MANAGER" ]] || die "Missing manager script: $MANAGER"

log "Repository: $REPO_DIR"
log "Backend:    $BACKEND_SSH"
log "Mode:       $MODE"

run ssh -o BatchMode=yes -o ConnectTimeout=10 "$BACKEND_SSH" "hostname; nvidia-smi --query-gpu=name,memory.total --format=csv,noheader"

if [[ "$MODE" == "full-install" ]]; then
  log "Syncing repo to backend: $BACKEND_TARGET_DIR"
  run ssh "$BACKEND_SSH" "mkdir -p '$BACKEND_TARGET_DIR'"
  run rsync -a --delete --exclude .git/ "$REPO_DIR/" "$BACKEND_SSH:$BACKEND_TARGET_DIR/"

  install_args=(bash "$BACKEND_TARGET_DIR/install_vllm-v022.sh" --install-dir "$INSTALL_DIR")
  if [[ "$FORCE_CLEAN_INSTALL" == "1" ]]; then
    install_args+=(--force-clean)
  fi
  run ssh "$BACKEND_SSH" "$(quote_args "${install_args[@]}")"

  if [[ "$SKIP_MODEL_DOWNLOAD" != "1" ]]; then
    run perl "$REPO_DIR/download_model_on_backend_v022_qwen35b.pl" download \
      --backend-host="$BACKEND_HOST" \
      --backend-ssh-user="$BACKEND_USER" \
      --preset="$MODEL_PRESET"
  fi
fi

apply_args=(
  perl "$MANAGER" apply-all
  --backend-host="$BACKEND_HOST"
  --backend-port="$BACKEND_PORT"
  --gateway-port="$GATEWAY_PORT"
  --model-id="$MODEL_ID"
  --served-model-name="$SERVED_MODEL_NAME"
  --public-model-name="$SERVED_MODEL_NAME"
  --backend-model-name="$SERVED_MODEL_NAME"
  --gpu-memory-utilization="$GPU_MEMORY_UTILIZATION"
  --max-model-len="$MAX_MODEL_LEN"
  --max-num-seqs="$MAX_NUM_SEQS"
  --max-num-batched-tokens="$MAX_NUM_BATCHED_TOKENS"
  --tool-call-parser=qwen3_coder
  --reasoning-parser=qwen3
  --enable-thinking
  --no-language-model-only
  '--limit-mm-per-prompt={"image":4}'
  --max-concurrent-per-student="$MAX_CONCURRENT_PER_STUDENT"
  --rpm-limit="$RPM_LIMIT"
  --client-timeout="$CLIENT_TIMEOUT"
  --downstream-timeout="$DOWNSTREAM_TIMEOUT"
  --request-hard-timeout="$REQUEST_HARD_TIMEOUT"
  --max-children="$MAX_CHILDREN"
)
if [[ "$WITH_CLEANUP" == "1" ]]; then
  apply_args+=(--with-cleanup)
fi
if [[ "$WITH_WATCHDOG" == "1" ]]; then
  apply_args+=(--with-watchdog)
fi

run "${apply_args[@]}"
run perl "$MANAGER" status

log "Bootstrap complete."
