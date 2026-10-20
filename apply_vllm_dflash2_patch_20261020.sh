#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="/local_opt/vllm-install-qwen38-v0271/vllm"
BASE_COMMIT="6e448d0ea9bf3d88d898b65449ca6dc2aec170ac"
PATCH_FILE="$SCRIPT_DIR/patches/vllm_dflash2_20261020.patch"
PATCH_SOURCE="$SCRIPT_DIR/patches/vllm_dflash2_source/vllm"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE_ROOT="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--source-root PATH]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$SOURCE_ROOT/.git" ]] || { echo "vLLM source is not a git checkout: $SOURCE_ROOT" >&2; exit 1; }
[[ -f "$PATCH_FILE" ]] || { echo "Missing patch: $PATCH_FILE" >&2; exit 1; }
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$BASE_COMMIT" ]] || {
  echo "Unexpected vLLM base commit; expected $BASE_COMMIT" >&2
  git -C "$SOURCE_ROOT" rev-parse HEAD >&2
  exit 1
}

if git -C "$SOURCE_ROOT" apply --check "$PATCH_FILE"; then
  git -C "$SOURCE_ROOT" apply "$PATCH_FILE"
elif git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH_FILE"; then
  echo "Tracked DFlash2 patch already applied"
else
  echo "Tracked DFlash2 patch does not apply cleanly" >&2
  exit 1
fi

install -d "$SOURCE_ROOT/vllm/model_executor/models"
install -d "$SOURCE_ROOT/vllm/v1/worker/gpu/spec_decode/dflash2"
install -m 0644 \
  "$PATCH_SOURCE/vllm/model_executor/models/qwen3_dflash2.py" \
  "$SOURCE_ROOT/vllm/model_executor/models/qwen3_dflash2.py"
install -m 0644 \
  "$PATCH_SOURCE/vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py" \
  "$SOURCE_ROOT/vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py"
install -m 0644 \
  "$PATCH_SOURCE/vllm/v1/worker/gpu/spec_decode/dflash2/__init__.py" \
  "$SOURCE_ROOT/vllm/v1/worker/gpu/spec_decode/dflash2/__init__.py"

python3 -m py_compile \
  "$SOURCE_ROOT/vllm/config/vllm.py" \
  "$SOURCE_ROOT/vllm/model_executor/models/qwen3_dflash.py" \
  "$SOURCE_ROOT/vllm/model_executor/models/qwen3_dflash2.py" \
  "$SOURCE_ROOT/vllm/model_executor/models/registry.py" \
  "$SOURCE_ROOT/vllm/v1/worker/gpu/spec_decode/__init__.py" \
  "$SOURCE_ROOT/vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py"

echo "DFlash2 source patch applied: $SOURCE_ROOT"
