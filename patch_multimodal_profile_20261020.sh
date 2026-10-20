#!/usr/bin/env bash
set -euo pipefail

# Reviewed profile patch for cluster195/node13.  Keep the original files in a
# timestamped root-only backup before changing any production defaults.
MANAGER=/home/vLLM_installation_dgx_v22/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl
DEPLOYER=/home/vLLM_installation_dgx_v22/deploy_vllm4dgx_v022_qwen35b.pl
WATCHDOG=/usr/local/sbin/vllm_qwen35b_watchdog.sh
BACKUP_ROOT=/root/codex_backups_vllm_profile
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=$BACKUP_ROOT/$STAMP

mkdir -p "$BACKUP_DIR"
cp -a "$MANAGER" "$DEPLOYER" "$WATCHDOG" "$BACKUP_DIR"/

set_default() {
    local file=$1
    local key=$2
    local value=$3
    local count
    count=$(sed -n '1,120p' "$file" | grep -Ec "^[[:space:]]*$key[[:space:]]*=>" || true)
    if [[ "$count" != "1" ]]; then
        echo "expected exactly one default for $key in $file; got $count" >&2
        exit 1
    fi
    perl -0pi -e "s/^(\\s*\\Q$key\\E\\s*=>\\s*).*$/\${1}'$value',/m" "$file"
}

# Stable multimodal profile:
#   0.85 GPU memory, 131072 context, 16384 prefill batch, 10 sequences,
#   FP8 KV cache, four images per prompt, and DFlash speculative decoding.
set_default "$MANAGER" gpu_memory_utilization 0.85
set_default "$MANAGER" max_model_len 131072
set_default "$MANAGER" max_num_batched_tokens 16384
set_default "$MANAGER" speculative_method dflash
set_default "$MANAGER" num_speculative_tokens 7
set_default "$MANAGER" speculative_model /local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2
set_default "$MANAGER" draft_sample_method ''

set_default "$DEPLOYER" gpu_memory_utilization 0.85
set_default "$DEPLOYER" max_model_len 131072
set_default "$DEPLOYER" max_num_seqs 10
set_default "$DEPLOYER" limit_mm_per_prompt '{"image":4}'
set_default "$DEPLOYER" speculative_method dflash
set_default "$DEPLOYER" num_speculative_tokens 7
set_default "$DEPLOYER" speculative_model /local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2
set_default "$DEPLOYER" draft_sample_method ''

perl -c "$MANAGER"
perl -c "$DEPLOYER"
echo "profile patch complete; backup=$BACKUP_DIR"
