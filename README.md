# DGX Spark Qwen3.8 vLLM/DFlash2 — cluster195 Deployment

> **Production source of truth (2026-10-20):** cluster195 runs
> Qwen3.8-27B-NVFP4 with `deploy_qwen38_27b_dflash2.sh`. Older Qwen3.6/MTP
> values are historical documentation only.

This repository contains the operational and reproducible deployment tools for
the DGX Spark (GB10, aarch64) inference service:

```text
student/Hermes -> nginx on master:9000 -> vLLM on node13:8000
```

The model is served as `mel_llm`. Several script and watchdog filenames retain
the historical `qwen35b` suffix for compatibility with existing cron entries;
that suffix does not identify the current model.

## Current production profile

| Setting | Value |
|---|---|
| Target model | `/local_opt/vllm-models/nvidia-Qwen3.8-27B-NVFP4` |
| vLLM source | `6e448d0ea9bf3d88d898b65449ca6dc2aec170ac` plus DFlash2 patch |
| vLLM runtime | `0.27.2.dev0+g6e448d0ea.d20260923` |
| `gpu-memory-utilization` | `0.85` |
| `max-model-len` | `131072` |
| `max-num-batched-tokens` | `16384` |
| `max-num-seqs` | `10` |
| `kv-cache-dtype` | `fp8` |
| multimodal | enabled, up to `{"image":4}` per prompt |
| speculative decoding | DFlash2, `7` tokens |
| thinking | disabled by default |
| performance | throughput mode, optimization level `2` |
| gateway rate limit | `60` requests/minute per student |

The latest low-impact sequential benchmark was `27.46 completion tok/s` with
DFlash2 and `9.63 tok/s` without speculative decoding. These are sequential
measurements, not a production concurrency/load guarantee.

### Gateway concurrency

nginx generates real `limit_conn` zones. Limits are active HTTP inference
connections per authenticated student:

| Student class | Active limit | Overflow |
|---|---:|---|
| Default | 2 | HTTP 429 |
| `dsh` | 6 | HTTP 429 |
| `hermes` | 6 | HTTP 429 |
| `jsp` | 6 | HTTP 429 |

The default is in `gateway_config.json`; `dsh`, `hermes`, and `jsp` overrides
are in the protected runtime student records. Tokens and generated nginx files
are never committed.

### Watchdog and planned restarts

`/usr/local/sbin/vllm_qwen35b_watchdog.sh` runs every two minutes. It performs
a real `/v1/chat/completions` probe and restarts the backend after three
consecutive failures, with a 15-minute cooldown. The manager writes a
maintenance marker before a planned model load so the watchdog cannot race it.
If node13 itself is unreachable, the watchdog can only record the failure; a
host reboot or hardware recovery is required first.

After a host reboot, run:

```bash
cd /home/vLLM_installation_dgx_v22
bash ./deploy_qwen38_27b_dflash2.sh --deploy
/usr/local/sbin/vllm_qwen35b_watchdog.sh
```

The final command should append `PROBE_OK` to
`/var/log/vllm_qwen35b_watchdog.log`.

---

## Quick Reference

| Component | Host | Port | Config Dir |
|-----------|------|------|------------|
| Gateway (nginx) | master (cluster195) | 9000 | `/etc/nginx/conf.d/vllm-gateway.conf` |
| Backend (vLLM) | node13 | 8000 | `/local_opt/vllm-service-qwen35b/` |
| Install root | node13 | — | `/local_opt/vllm-install-qwen38-v0271/` |
| Model storage | node13 | — | `/local_opt/vllm-models/` |
| Scripts | master | — | `./` |

---

## Directory Structure

```
./
├── deploy_nginx_gateway_v022_qwen35b.pl      # Nginx gateway installer/manager
├── manage_lab_vllm_nginx_from_master_v022_qwen35b.pl  # Main orchestrator (nginx)
├── deploy_vllm4dgx_v022_qwen35b.pl           # Backend vLLM deployer (node13)
├── bootstrap_new_cluster_v022_qwen35b.sh     # New-machine bootstrap wrapper
├── install_vllm-v022.sh                      # One-click installer
├── deploy_qwen38_27b_dflash2.sh               # Current production wrapper
├── apply_vllm_dflash2_patch_20261020.sh       # Exact source patch
├── configure_gateway_student_limits_20261020.sh # dsh/hermes limits
├── smoke_test_vllm_v022_qwen35b_a3b.sh       # Backend smoke test
├── download_model_on_backend_v022_qwen35b.pl # Model downloader
├── test_vllm_ps_v022_qwen35b_a3b.pl          # Process status checker
├── benchmark_vllm_token_rate_v022_qwen35b.pl # Token rate benchmark
├── run_model_benchmarks.sh                   # Legacy benchmark runner
├── run_vllm_sweep.sh                         # Legacy parameter sweep
├── continue_sweep.sh                         # Legacy sweep continuation
├── nemotron_param_sweep.sh                   # Legacy Nemotron sweep
├── opencode_quality_ab.sh                    # Legacy A/B quality test
├── Perl_gateway/                             # Legacy Perl gateway scripts
│   ├── deploy_lab_vllm_gateway_v022_qwen35b.pl
│   ├── manage_lab_vllm_from_master_v022_qwen35b.pl
│   └── clean-lab-vllm-slots_v022.sh
└── README.md
```

---

## Architecture

```
                       ┌─────────────┐
  Student ──:9000 ──▶  │   nginx     │  (auth via map + rate limiting)
                       │  (master)   │
                       └──────┬──────┘
                              │ proxy_pass
                              ▼
                       ┌─────────────┐
                       │  vLLM       │  (backend on node13)
                       │  :8000      │
                       └─────────────┘
```

- **nginx** handles authentication (Bearer token → student ID via `map`), rate limiting (`limit_req_zone` per token), and reverse proxying.
- **SELinux**: `httpd_can_network_connect` enabled automatically.
- **Firewall**: Port 9000 opened automatically.

---

## Installation

### Reproducible Qwen3.8/DFlash2 rebuild (current production)

Run the following from the cluster195 master unless noted otherwise. The
master is an administrative gateway; vLLM and GPU workloads run only on
node13.

1. Clone the repository on the master and copy the checked-out source to
   node13. The installer needs the patch files locally on node13.

```bash
git clone https://github.com/jushinpon/vLLM_installation_dgx_v22.git \
  /home/vLLM_installation_dgx_v22
cd /home/vLLM_installation_dgx_v22
rsync -a --delete --exclude .git/ ./ \
  root@node13:/home/vLLM_installation_dgx_v22/
```

2. Rebuild the exact vLLM environment on node13:

```bash
ssh root@node13 \
  'cd /home/vLLM_installation_dgx_v22 && \
   bash install_vllm-v022.sh --profile qwen38-v0271 \
     --install-dir /local_opt/vllm-install-qwen38-v0271'
```

The profile pins the base vLLM commit, installs the CUDA 13 Python stack,
applies `patches/vllm_dflash2_20261020.patch` and the DFlash2 source files,
and builds vLLM. The captured package set is recorded in
`requirements_qwen38_dflash2_20261020.txt`.

3. Provision the model artifacts under `/local_opt/vllm-models/`, then deploy:

```bash
bash ./deploy_qwen38_27b_dflash2.sh --all
bash ./configure_gateway_student_limits_20261020.sh
```

The wrapper deploys the multimodal DFlash2 profile and installs the generated
watchdog. The second command applies the non-secret `dsh=6` and `hermes=6`
gateway overrides after student tokens have been provisioned. For an existing
installation, use `--deploy` or `--watchdog` independently.

The NVIDIA model weights, DFlash2 draft weights, student tokens, private keys,
logs, caches, and generated `/etc/nginx` or `/usr/local/sbin` files are runtime
artifacts and are intentionally not stored in GitHub.

See `README_dflash2.md` for the exact patch inventory and validation record.

### New Machine Bootstrap

After cloning this repo on the master node, use the legacy bootstrap wrapper only for a new
cluster. It copies the repo to the backend node, installs vLLM, downloads the
Qwen3.6 35B-A3B FP8 legacy model, deploys the backend and nginx gateway, and installs
the cron watchdog. This path is not the current Qwen3.8 DFlash2 production deployment; use deploy_qwen38_27b_dflash2.sh instead.

Prerequisites before running the bootstrap:

- Run from the master node.
- Passwordless SSH from master to backend works, for example `ssh root@node13 hostname`.
- Backend has a working NVIDIA driver, CUDA runtime, `nvidia-smi`, and enough disk space under `/local_opt`.
- `uv` is installed on the backend, or install it first with the standard Astral `uv` installer.
- Hugging Face access is configured if the selected model requires authentication.
- The target backend hostname is known, usually `node13` on cluster195.

Recommended end-to-end flow for a fresh machine:

1. Clone this repo on the master node.
2. Confirm master can SSH to the backend as root without a password.
3. Confirm the backend has NVIDIA driver/CUDA, enough `/local_opt` disk space, and `uv`.
4. Run bootstrap with `--dry-run`.
5. Run bootstrap with `--full-install`.
6. Verify gateway, backend model name, `131072` context, and watchdog log.
7. Add or rotate student tokens with the gateway manager.
8. Export the student token as `VLLM_API_KEY` before running benchmarks.

```bash
cd /home/vLLM_installation_dgx_v22
bash bootstrap_new_cluster_v022_qwen35b.sh --full-install \
  --backend-host=node13
```

For a machine that already has vLLM and the model installed, only reapply the
runtime and gateway settings:

```bash
cd /home/vLLM_installation_dgx_v22
bash bootstrap_new_cluster_v022_qwen35b.sh --apply-only \
  --backend-host=node13
```

### Native Qwen3.8-27B Profile (alternative, non-production)

`deploy_qwen38_27b_native_v0271.sh` deploys
`Frozenlock/Qwen3.8-27B-int4-AutoRound` without Docker. It uses the
repository installer, downloader, backend manager, smoke test, and watchdog,
but keeps its runtime roots isolated from the legacy Qwen3.6 installation.
It intentionally preserves the existing backend contract: port `8000`, served
model name `mel_llm`, default `enable_thinking=false`, and the existing gateway
configuration. No Hermes provider or model-name change is required.

Run these commands on the master node:

```bash
cd /home/vLLM_installation_dgx_v22

# Build the isolated native runtime from v0.27.1 source, then fetch its checkpoint.
bash ./deploy_qwen38_27b_native_v0271.sh --install
bash ./deploy_qwen38_27b_native_v0271.sh --download

# Deploy the isolated native experiment only when explicitly requested.
bash ./deploy_qwen38_27b_native_v0271.sh --deploy

# Install its watchdog after smoke/benchmark checks.
bash ./deploy_qwen38_27b_native_v0271.sh --watchdog
```

## Health checks and operations

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl status
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-smoke
curl -s http://127.0.0.1:9000/healthz
ssh root@node13 'curl -s http://127.0.0.1:8000/v1/models'
tail -20 /var/log/vllm_qwen35b_watchdog.log
nginx -t && systemctl reload nginx
```

Expected results are model `mel_llm`, healthy gateway/backend endpoints, and a
watchdog `PROBE_OK`. A planned model load may temporarily log
`PROBE_SKIPPED maintenance_active`.

Gateway limit commands:

```bash
perl deploy_nginx_gateway_v022_qwen35b.pl list-students
perl deploy_nginx_gateway_v022_qwen35b.pl \
  set-student-limits --student-id=dsh --max-concurrent=6
perl deploy_nginx_gateway_v022_qwen35b.pl \
  set-student-limits --student-id=hermes --max-concurrent=6
perl deploy_nginx_gateway_v022_qwen35b.pl \
  set-student-limits --student-id=jsp --max-concurrent=6
```

## Runtime paths

| Component | Location |
|---|---|
| Backend service stack | `/local_opt/vllm-service-qwen35b/` |
| vLLM environment | `/local_opt/vllm-install-qwen38-v0271/` |
| Model weights | `/local_opt/vllm-models/` |
| Generated watchdog | `/usr/local/sbin/vllm_qwen35b_watchdog.sh` |
| Watchdog log/state | `/var/log/vllm_qwen35b_watchdog.log`, `/var/lib/vllm_qwen35b_watchdog/` |
| nginx config | `/etc/nginx/conf.d/vllm-gateway.conf` |
| Gateway config | `/local_opt/lab-vllm-gateway/config/gateway_config.json` |
| Student tokens | `/local_opt/lab-vllm-gateway/config/students_tokens.json` |

## Validation before commit or deployment

```bash
perl -c manage_lab_vllm_nginx_from_master_v022_qwen35b.pl
perl -c deploy_vllm4dgx_v022_qwen35b.pl
perl -c deploy_nginx_gateway_v022_qwen35b.pl
bash -n install_vllm-v022.sh
bash -n apply_vllm_dflash2_patch_20261020.sh
bash -n deploy_qwen38_27b_dflash2.sh
bash -n configure_gateway_student_limits_20261020.sh
bash -n capture_vllm_forensics_v022.sh
bash -n smoke_test_vllm_v022_qwen35b_a3b.sh
git diff --check
```

After deployment, verify `/v1/models`, one real chat completion, `nginx -t`,
the watchdog log, and the active vLLM command line on node13. Do not run load
tests while student requests are active.

For the exact DFlash2 patch inventory and benchmark record, read
`README_dflash2.md`. Historical Qwen3.6 deployment and rollback notes remain
under `patch_20260630/` and must not be used as the current production profile.
