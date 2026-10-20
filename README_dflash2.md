# Qwen3.8-27B-NVFP4 + DFlash2 on cluster195/node13

This is the reproducible production profile validated on the NVIDIA GB10
node13.  The source checkout is vLLM commit
`6e448d0ea9bf3d88d898b65449ca6dc2aec170ac` plus the DFlash2 patch bundle in
`patches/`.

## Validated runtime

| Setting | Value |
|---|---|
| vLLM | `0.27.2.dev0+g6e448d0ea.d20260923` |
| Base source commit | `6e448d0ea9bf3d88d898b65449ca6dc2aec170ac` |
| Target model | `/local_opt/vllm-models/nvidia-Qwen3.8-27B-NVFP4` |
| DFlash2 model | `/local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2` |
| Served model | `mel_llm` |
| API | node13:8000, nginx gateway:9000 |
| GPU memory utilization | `0.85` |
| Max model length | `131072` |
| Max batched tokens | `16384` |
| Max sequences | `10` |
| KV cache | `fp8` |
| Speculative method | `dflash`, `7` tokens |
| Multimodal | enabled, up to `{"image":4}` |
| Thinking | disabled by default |
| Performance | throughput mode, optimization level 2 |

## Gateway concurrency

The nginx generator creates real `limit_conn` zones:

```text
default students: 4 active HTTP inference connections
dsh:              6
hermes:           6
jsp:              6
overflow:         HTTP 429
```

Student API tokens are deliberately not stored in this repository.  The
runtime student-token file is provisioned separately, and the generator reads
the non-secret `max_concurrent` overrides from that file.

## Reproduce the installation

Run the installer on node13 with this repository directory available there:

```bash
bash install_vllm-v022.sh --profile qwen38-v0271 \
  --install-dir /local_opt/vllm-install-qwen38-v0271
```

The `qwen38-v0271` profile pins the base vLLM commit, installs the CUDA 13
PyTorch stack, applies `apply_vllm_dflash2_patch_20261020.sh`, and builds vLLM
from source.  The NVIDIA model weights and DFlash2 draft weights are separate
artifacts and must already be available or downloaded by the deployment script.
The captured package set is recorded in
`requirements_qwen38_dflash2_20261020.txt`.

From the master checkout, deploy the backend and watchdog with:

```bash
bash deploy_qwen38_27b_dflash2.sh --all
```

For an existing installation, use `--deploy` or `--watchdog` independently.
The manager performs the planned backend restart and writes the maintenance
marker so the watchdog cannot race model startup.

## Gateway setup

The gateway source is `deploy_nginx_gateway_v022_qwen35b.pl`.  It generates
`/etc/nginx/conf.d/vllm-gateway.conf` from the runtime configuration and
student-token file, then validates and reloads nginx.  The generated config and
tokens are runtime files and must not be committed.

The manager default is `max_concurrent_per_student=4`; the current `dsh`,
`hermes`, and `jsp` accounts are set to `6` by their runtime student records.

After provisioning the student-token file, apply those non-secret overrides
with:

```bash
bash configure_gateway_student_limits_20261020.sh
```

## Validation

```bash
perl -c manage_lab_vllm_nginx_from_master_v022_qwen35b.pl
perl -c deploy_vllm4dgx_v022_qwen35b.pl
perl -c deploy_nginx_gateway_v022_qwen35b.pl
bash -n install_vllm-v022.sh
bash -n apply_vllm_dflash2_patch_20261020.sh
bash -n deploy_qwen38_27b_dflash2.sh
bash -n patch_multimodal_profile_20261020.sh
bash -n verify_multimodal_profile_20261020.sh
```

The latest low-impact sequential benchmark was `27.46 completion tok/s` with
DFlash enabled, compared with `9.63 tok/s` without speculative decoding.  This
is a sequential benchmark, not a production concurrency/load test.

## Secrets and generated files

Do not commit API tokens, private keys, logs, GPU caches, model weights, or
generated runtime files.  The watchdog at
`/usr/local/sbin/vllm_qwen35b_watchdog.sh` is generated from the manager and
therefore is not the source of truth.
