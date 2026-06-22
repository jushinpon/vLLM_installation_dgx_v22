#!/bin/bash
################################################################################
# One-click vLLM v0.22.0 installer for NVIDIA DGX Spark / GB10
#
# Target:
#   - DGX OS / NVIDIA GB10 / Blackwell / aarch64
#   - CUDA 13.0 PyTorch stack
#   - vLLM v0.22.0 source build
#
# Default install directory:
#   /local_opt/vllm-install
#
# Usage:
#   bash install_vllm-v022.sh \
#     --install-dir /local_opt/vllm-install \
#     --force-clean \
#     |& tee /home/install-vllm-v022.log
#
# Start server:
#   bash /local_opt/vllm-install/run_qwen35_35b_a3b.sh
################################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
  echo; echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"; echo -e "${BLUE}========================================${NC}"; echo
}

INSTALL_DIR="/local_opt/vllm-install"
VLLM_VERSION="v0.22.0"
PYTORCH_VERSION="2.11.0"
TORCHVISION_VERSION="0.26.0"
TORCHAUDIO_VERSION="2.11.0"
PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"
PYTHON_VERSION="3.12"
MODEL_ID="Qwen/Qwen3.6-35B-A3B-FP8"
SERVED_MODEL_NAME="qwen3.6-35b-a3b-fp8"
HOST="0.0.0.0"
PORT="8000"
MAX_MODEL_LEN="32768"
MAX_NUM_SEQS="16"
MAX_NUM_BATCHED_TOKENS="8192"
GPU_MEMORY_UTILIZATION="0.70"
REASONING_PARSER="qwen3"
TOOL_CALL_PARSER="qwen3_coder"
FORCE_CLEAN="0"
BACKUP_EXISTING="1"

show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --install-dir DIR       Install directory (default: /local_opt/vllm-install)
  --vllm-version VER      vLLM version/tag (default: v0.22.0)
  --python-version VER    Python version for venv (default: 3.12)
  --force-clean           Remove existing install dir before starting
  --model-id ID           HuggingFace model ID
  --served-model-name NAME Model name for API
  --help                  Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --vllm-version) VLLM_VERSION="$2"; shift 2 ;;
    --python-version) PYTHON_VERSION="$2"; shift 2 ;;
    --force-clean) FORCE_CLEAN="1"; shift ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --served-model-name) SERVED_MODEL_NAME="$2"; shift 2 ;;
    --help) show_help ;;
    *) log_error "Unknown option: $1"; show_help ;;
  esac
done

check_prerequisites() {
  print_header "Checking prerequisites"
  for cmd in git python3 curl nvidia-smi; do
    if ! command -v "$cmd" >/dev/null 2>&1; then log_error "$cmd is required but not found."; exit 1; fi
    log_info "Found: $cmd"
  done
  if [[ -x /usr/local/cuda/bin/nvcc ]]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    log_info "Found nvcc: $(nvcc --version | tail -1)"
  else
    log_warning "nvcc not found at /usr/local/cuda/bin/nvcc"
  fi
  if command -v uv >/dev/null 2>&1; then
    log_info "Found uv: $(uv --version)"
  elif [[ -x /root/.local/bin/uv ]]; then
    export PATH="/root/.local/bin:$PATH"
    log_info "Found uv: $(uv --version)"
  else
    log_error "uv is required. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1
  fi
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  log_info "Disk available: $(df -h / | tail -1 | awk '{print $4}')"
}

prepare_install_dir() {
  print_header "Preparing install directory"
  if [[ -d "$INSTALL_DIR" ]]; then
    if [[ "$FORCE_CLEAN" == "1" ]]; then
      log_warning "Removing existing install directory: $INSTALL_DIR"
      rm -rf "$INSTALL_DIR"
    elif [[ "$BACKUP_EXISTING" == "1" ]]; then
      local backup_dir="${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
      log_warning "Backing up existing directory to: $backup_dir"
      mv "$INSTALL_DIR" "$backup_dir"
    fi
  fi
  mkdir -p "$INSTALL_DIR"
  log_info "Install directory: $INSTALL_DIR"
}

setup_venv() {
  print_header "Setting up Python virtual environment"
  uv venv "$INSTALL_DIR/.vllm" --python "$PYTHON_VERSION" --seed
  source "$INSTALL_DIR/.vllm/bin/activate"
  python -V
  python -m pip install --upgrade pip
  log_success "Virtual environment created at $INSTALL_DIR/.vllm"
}

install_pytorch() {
  print_header "Installing PyTorch CUDA 13.0 stack"
  source "$INSTALL_DIR/.vllm/bin/activate"
  uv pip install --index-url "$PYTORCH_INDEX_URL" \
    torch==$PYTORCH_VERSION \
    torchvision==$TORCHVISION_VERSION \
    torchaudio==$TORCHAUDIO_VERSION
  python -c "import torch; print('PyTorch:', torch.__version__); print('CUDA:', torch.cuda.is_available()); print('Device:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')"
  log_success "PyTorch CUDA stack installed"
}

install_dependencies() {
  print_header "Installing build and runtime dependencies"
  source "$INSTALL_DIR/.vllm/bin/activate"

  uv pip install cmake ninja 'setuptools>=77.0.3,<81.0.0'

  # v0.22.0 CUDA deps
  uv pip install \
    numba==0.65.0 \
    flashinfer-python==0.6.11.post2 \
    flashinfer-cubin==0.6.11.post2 \
    'nvidia-cutlass-dsl[cu13]==4.5.2' \
    tilelang==0.1.9 \
    'quack-kernels>=0.3.3' \
    tokenspeed-mla==0.1.2 \
    'humming-kernels[cu13]==0.1.2' \
    'nvidia-cudnn-frontend>=1.13.0,<1.19.0' \
    'fastsafetensors>=0.2.2'

  # v0.22.0 common deps
  uv pip install \
    'transformers>=4.56.0,!=5.0.*' \
    'tokenizers>=0.21.1' \
    'safetensors>=0.6.2' \
    'fastapi[standard]>=0.115.0' \
    'aiohttp>=3.13.3' 'openai>=2.0.0' 'pydantic>=2.12.0' \
    prometheus_client pillow 'prometheus-fastapi-instrumentator>=7.0.0' \
    'tiktoken>=0.6.0' 'lm-format-enforcer==0.11.3' \
    'llguidance>=1.7.0,<1.8.0' 'outlines_core==0.2.14' \
    diskcache==5.6.3 lark==1.2.2 'xgrammar>=0.2.0,<1.0.0' \
    'typing_extensions>=4.10' 'filelock>=3.16.1' partial-json-parser \
    'pyzmq>=25.0.0' msgspec 'gguf>=0.17.0' 'mistral_common[image]>=1.11.2' \
    'opencv-python-headless>=4.13.0' pyyaml 'six>=1.16.0' einops \
    'compressed-tensors==0.15.0.1' depyf==0.20.0 cloudpickle watchfiles \
    python-json-logger pybase64 cbor2 ijson setproctitle \
    regex cachetools psutil sentencepiece numpy 'requests>=2.26.0' \
    tqdm blake3 py-cpuinfo

  log_success "Dependencies installed"
}

clone_vllm() {
  print_header "Cloning vLLM v${VLLM_VERSION}"
  source "$INSTALL_DIR/.vllm/bin/activate"
  rm -rf "${INSTALL_DIR}/vllm"
  cd "$INSTALL_DIR"
  git clone --recursive https://github.com/vllm-project/vllm.git
  cd "${INSTALL_DIR}/vllm"
  git checkout "$VLLM_VERSION"
  git submodule update --init --recursive
  sed -i 's/^license = "Apache-2.0"$/license = {text = "Apache-2.0"}/' pyproject.toml || true
  sed -i '/^license-files = /d' pyproject.toml || true
  log_success "vLLM source cloned"
}

clean_vllm_build_tree() {
  cd "${INSTALL_DIR}/vllm"
  rm -rf build dist .pytest_cache .setuptools-cmake-build vllm.egg-info
  find . -name '*.so' -delete 2>/dev/null || true
  find . -name '*.o' -delete 2>/dev/null || true
  find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

build_vllm() {
  print_header "Building vLLM from source"
  source "$INSTALL_DIR/.vllm/bin/activate"
  export PATH="/usr/local/cuda/bin:$PATH"
  clean_vllm_build_tree
  cd "${INSTALL_DIR}/vllm"
  export TORCH_CUDA_ARCH_LIST="12.1a"
  export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
  export CMAKE_BUILD_PARALLEL_LEVEL
  CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)
  log_info "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST  CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL"
  python -m pip install --no-build-isolation --no-deps -e . 2>&1 | tee "${INSTALL_DIR}/vllm-build.log"
  log_success "vLLM built and installed"
}

verify_installation() {
  print_header "Verifying installation"
  source "$INSTALL_DIR/.vllm/bin/activate"
  export PATH="/usr/local/cuda/bin:$PATH"
  python -c "import vllm; print('vLLM:', vllm.__version__)"
  python -c "import torch; print('Torch:', torch.__version__); print('CUDA:', torch.cuda.is_available()); print('Device:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')"
  pip check 2>&1 | tee "${INSTALL_DIR}/pip-check.log" || true
}

create_launcher() {
  print_header "Creating launcher script"
  cat > "${INSTALL_DIR}/run_qwen35_35b_a3b.sh" << 'LAUNCHER_EOF'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="/local_opt/vllm-install"
MODEL_ID="Qwen/Qwen3.6-35B-A3B-FP8"
SERVED_MODEL_NAME="qwen3.6-35b-a3b-fp8"
HOST="0.0.0.0"
PORT="8000"
MAX_MODEL_LEN="32768"
MAX_NUM_SEQS="16"
MAX_NUM_BATCHED_TOKENS="8192"
GPU_MEMORY_UTILIZATION="0.70"
REASONING_PARSER="qwen3"
TOOL_CALL_PARSER="qwen3_coder"

source "${INSTALL_DIR}/.vllm/bin/activate"
export PATH="/usr/local/cuda/bin:$PATH"
export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export HF_HUB_ENABLE_HF_TRANSFER=1

echo "Starting vLLM v0.22.0 server..."
exec python -m vllm.entrypoints.openai.api_server \
  --model "${MODEL_ID}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --host "${HOST}" --port "${PORT}" \
  --dtype auto --tensor-parallel-size 1 \
  --max-model-len "${MAX_MODEL_LEN}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}" \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
  --reasoning-parser "${REASONING_PARSER}" \
  --enable-auto-tool-choice --tool-call-parser "${TOOL_CALL_PARSER}" \
  --enable-chunked-prefill --enable-prefix-caching \
  --language-model-only --trust-remote-code
LAUNCHER_EOF
  chmod +x "${INSTALL_DIR}/run_qwen35_35b_a3b.sh"
  log_success "Launcher script created"
}

generate_summary() {
  source "$INSTALL_DIR/.vllm/bin/activate"
  export PATH="/usr/local/cuda/bin:$PATH"
  cat > "${INSTALL_DIR}/ENVIRONMENT_SUMMARY.txt" << SUMMARY_EOF
Installation time       : $(date)
Install directory       : $INSTALL_DIR
vLLM source version/tag : $VLLM_VERSION
Target model            : $MODEL_ID
Served model name       : $SERVED_MODEL_NAME
Host                    : $HOST
Port                    : $PORT
Max model length        : $MAX_MODEL_LEN
Max num seqs            : $MAX_NUM_SEQS
Max batched tokens      : $MAX_NUM_BATCHED_TOKENS
GPU memory utilization  : $GPU_MEMORY_UTILIZATION

GPU:
$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1)

Python packages:
$(pip list 2>/dev/null | grep -iE "torch|triton|transformers|vllm|flashinfer|cutlass" | sort)
SUMMARY_EOF
  log_success "Environment summary written"
}

main() {
  echo; echo -e "${GREEN}=== vLLM v${VLLM_VERSION} Installer for DGX Spark / GB10 ===${NC}"
  echo "Install dir: $INSTALL_DIR"; echo
  check_prerequisites
  prepare_install_dir
  setup_venv
  install_pytorch
  install_dependencies
  clone_vllm
  build_vllm
  verify_installation
  create_launcher
  generate_summary
  print_header "Installation Complete"
  log_success "vLLM $VLLM_VERSION installed!"
  echo "  Launcher: ${INSTALL_DIR}/run_qwen35_35b_a3b.sh"
  echo "  Build log: ${INSTALL_DIR}/vllm-build.log"
}

main
