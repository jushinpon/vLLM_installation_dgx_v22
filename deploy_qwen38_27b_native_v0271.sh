#!/usr/bin/env bash
# Native Qwen3.8-27B rollout for cluster195. This deliberately reuses the
# repository's installer, downloader, manager, and watchdog rather than a
# Docker runtime or an ad hoc vLLM command.
set -euo pipefail

SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_HOST="node13"
ACTION="all"
DRY_RUN=0

RUNTIME_ROOT="/local_opt/vllm-install-qwen38-v0271"
STACK_ROOT="/local_opt/vllm-service-qwen38-v0271"
CACHE_ROOT="/local_opt/vllm-cache-qwen38-v0271"
HF_ROOT="/local_opt/hf-vllm-qwen38-v0271"
TMP_ROOT="/local_opt/tmp-vllm-qwen38-v0271"
MODEL_DIR="/local_opt/vllm-models/Frozenlock-Qwen3.8-27B-int4-AutoRound"

usage() {
  cat <<'EOF'
Usage: deploy_qwen38_27b_native_v0271.sh [options]

Actions (one at a time):
  --all                 Native install, model download, then backend restart.
  --install             Build the isolated native vLLM 0.27.1 runtime only.
  --download            Download/inspect the AutoRound model only.
  --deploy              Restart backend using the isolated runtime only.
  --watchdog            Install watchdog config for the Qwen3.8 runtime only.

Options:
  --backend-host HOST   Internal backend hostname (default: node13)
  --dry-run             Print commands without running them
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ACTION="all"; shift ;;
    --install) ACTION="install"; shift ;;
    --download) ACTION="download"; shift ;;
    --deploy) ACTION="deploy"; shift ;;
    --watchdog) ACTION="watchdog"; shift ;;
    --backend-host) BACKEND_HOST="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  (( DRY_RUN )) || "$@"
}

runtime_args=(
  "--backend-host=$BACKEND_HOST"
  "--backend-install-root=$RUNTIME_ROOT"
  "--backend-venv-root=$RUNTIME_ROOT/.vllm"
  "--backend-vllm-src-root=$RUNTIME_ROOT/vllm"
  "--backend-expected-triton-version=3.7.1"
  "--backend-stack-root=$STACK_ROOT"
  "--backend-cache-root=$CACHE_ROOT"
  "--backend-hf-root=$HF_ROOT"
  "--backend-tmp-root=$TMP_ROOT"
  "--model-id=$MODEL_DIR"
  "--served-model-name=mel_llm"
  "--gpu-memory-utilization=0.90"
  "--kv-cache-dtype=fp8"
  "--max-model-len=262144"
  "--max-num-batched-tokens=32768"
  "--max-num-seqs=10"
  "--tool-call-parser=qwen3_xml"
  "--reasoning-parser=qwen3"
  "--default-chat-template-kwargs={\"enable_thinking\":false}"
  "--no-language-model-only"
  "--limit-mm-per-prompt={\"image\":4}"
  "--speculative-method=mtp"
  "--performance-mode="
  "--optimization-level="
)

install_runtime() {
  run ssh "root@$BACKEND_HOST" \
    "cd '$SETUP_DIR' && bash ./install_vllm-v022.sh --profile qwen38-v0271 --install-dir '$RUNTIME_ROOT'"
}

download_model() {
  run perl "$SETUP_DIR/download_model_on_backend_v022_qwen35b.pl" download \
    "--preset=qwen38_27b_autoround_int4" \
    "--backend-host=$BACKEND_HOST" \
    "--backend-python=$RUNTIME_ROOT/.vllm/bin/python"
}

deploy_backend() {
  run perl "$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl" backend-restart \
    "${runtime_args[@]}"
}

install_watchdog() {
  run perl "$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl" install-watchdog \
    "${runtime_args[@]}"
}

case "$ACTION" in
  all)
    install_runtime
    download_model
    deploy_backend
    ;;
  install) install_runtime ;;
  download) download_model ;;
  deploy) deploy_backend ;;
  watchdog) install_watchdog ;;
esac
