#!/usr/bin/env bash
# Reproduce the validated Qwen3.8-27B-NVFP4 + DFlash2 deployment on cluster195.
set -euo pipefail

SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_HOST="node13"

RUNTIME_ROOT="/local_opt/vllm-install-qwen38-v0271"
STACK_ROOT="/local_opt/vllm-service-qwen35b"
CACHE_ROOT="/local_opt/vllm-cache"
HF_ROOT="/local_opt/hf-vllm"
TMP_ROOT="/local_opt/tmp-vllm"
TARGET_MODEL="/local_opt/vllm-models/nvidia-Qwen3.8-27B-NVFP4"
DRAFT_MODEL="/local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2"

usage() {
  cat <<EOF
Usage: deploy_qwen38_27b_dflash2.sh [options]

Actions:
  --all        Download draft model, deploy backend, and install watchdog
  --download   Download draft model only
  --deploy     Deploy backend only (assumes model already downloaded)
  --watchdog   Install the validated DFlash2 watchdog profile only

Options:
  --backend-host HOST   (default: node13)
  --help
EOF
}

ACTION="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ACTION="all"; shift ;;
    --download) ACTION="download"; shift ;;
    --deploy) ACTION="deploy"; shift ;;
    --watchdog) ACTION="watchdog"; shift ;;
    --backend-host) BACKEND_HOST="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

download_draft() {
  echo "=== Downloading DFlash2 draft model ==="
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$BACKEND_HOST" \
    "source $RUNTIME_ROOT/.vllm/bin/activate && \
     export HF_HUB_ENABLE_HF_TRANSFER=1 && \
     python3 -c \"from huggingface_hub import snapshot_download; snapshot_download('incoai/Qwen3.8-27B-DFlash2', local_dir='$DRAFT_MODEL')\""
  echo "DRAFT_MODEL_DOWNLOADED"
}

manager_common_args() {
  cat <<EOF
--backend-host=$BACKEND_HOST
--backend-install-root=$RUNTIME_ROOT
--backend-venv-root=$RUNTIME_ROOT/.vllm
--backend-vllm-src-root=$RUNTIME_ROOT/vllm
--backend-expected-triton-version=3.7.1
--backend-stack-root=$STACK_ROOT
--backend-cache-root=$CACHE_ROOT
--backend-hf-root=$HF_ROOT
--backend-tmp-root=$TMP_ROOT
--model-id=$TARGET_MODEL
--served-model-name=mel_llm
--gpu-memory-utilization=0.85
--max-model-len=131072
--max-num-batched-tokens=16384
--max-num-seqs=10
--kv-cache-dtype=fp8
--tool-call-parser=qwen3_xml
--reasoning-parser=qwen3
--default-chat-template-kwargs={"enable_thinking":false}
--no-language-model-only
--limit-mm-per-prompt={"image":4}
--speculative-method=dflash
--speculative-model=$DRAFT_MODEL
--num-speculative-tokens=7
--performance-mode=throughput
--optimization-level=2
EOF
}

deploy_backend() {
  echo "=== Deploying validated vLLM DFlash2 profile ==="
  mapfile -t args < <(manager_common_args)
  perl "$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl" \
    backend-restart "${args[@]}" --smoke-test-after-start
}

install_watchdog() {
  echo "=== Installing validated DFlash2 watchdog profile ==="
  mapfile -t args < <(manager_common_args)
  perl "$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl" \
    install-watchdog "${args[@]}"
}

case "$ACTION" in
  all) download_draft && deploy_backend && install_watchdog ;;
  download) download_draft ;;
  deploy) deploy_backend ;;
  watchdog) install_watchdog ;;
esac
