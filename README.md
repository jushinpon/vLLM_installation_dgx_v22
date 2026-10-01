# DGX Spark Qwen3.8 vLLM/DFlash2 - cluster195 Deployment

> **Production source of truth (2026-10-01):** cluster195 runs Qwen3.8-27B-NVFP4 with the DFlash2 wrapper `deploy_qwen38_27b_dflash2.sh`. The active profile is documented below. Older Qwen3.6/MTP values are legacy documentation only; do not use them for production restarts.

Current cluster195 inference serving system for **DGX Spark (GB10, aarch64)**.
Model: `nvidia-Qwen3.8-27B-NVFP4` (production NVFP4 model; FP8 is used for the KV cache).

Compatibility note: operational script and watchdog filenames still contain
`qwen35b` so existing cron entries and administrator commands keep working.
The generic manager defaults now match the Qwen3.8 NVFP4 + DFlash2 production profile; use the DFlash wrapper for explicit deployments.
**Nginx gateway** on master `:9000` — auth, rate limiting, proxying.
Backend vLLM on `node13:8000`.

## Production Profile

| Setting | Value |
|---|---:|
| `gpu-memory-utilization` | `0.85` |
| `max-model-len` | `262144` |
| `max-num-batched-tokens` | `32768` |
| `max-num-seqs` | `10` |
| `kv-cache-dtype` | `fp8` |
| multimodal image limit | `4` per prompt |
| speculative decoding | DFlash2, `7` tokens, probabilistic sampling |
| performance profile | `throughput`, optimization level `2` |
| thinking | disabled by default |
| gateway concurrency | `1` active request per student, up to 10 students |
| gateway rate limit | `60` requests/minute per student |

The DFlash wrapper and generic manager defaults intentionally match this table. The
watchdog installer receives the same explicit arguments, so an automatic restart
does not silently return to older memory, batching, concurrency, or image limits.

### Verified Throughput

Measurements on node13 with the production profile:

- `45.56` output tokens/s using the protocol from `gitcommit90/qwen38-27b-dgx-spark`
  (published reference: `44.46` output tokens/s).
- `58.16` output tokens/s using the pangoleen decode-only protocol.
- `188.16` aggregate output tokens/s with 10 concurrent users and
  `max-num-batched-tokens=32768`; the same run with `16384` measured `140.17`.

Results depend on prompt length, output length, cache state, and request mix. Use the
matching benchmark protocol when comparing numbers.

### Watchdog and Reboots

`/usr/local/sbin/vllm_qwen35b_watchdog.sh` runs every two minutes. It performs a real
`/v1/chat/completions` probe and restarts the backend after three consecutive failures,
with a 15-minute restart cooldown and a maintenance marker during planned model loads.
If node13 itself is unreachable, the watchdog records the failure but cannot restart a
host that does not accept SSH. After a manual host reboot, run:

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
| Backend (vLLM) | node13 | 8000 | `/local_opt/vllm-service-qwen38-v0271/` |
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
6. Verify gateway, backend model name, 262K shared-service context, and watchdog log.
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

# Build native vLLM from v0.27.1 source, then fetch the ~18 GiB checkpoint.
bash ./deploy_qwen38_27b_native_v0271.sh --install
bash ./deploy_qwen38_27b_dflash2.sh --download

# Take over node13:8000 only after the build and checkpoint are ready.
bash ./deploy_qwen38_27b_dflash2.sh --deploy

# Install the two-minute, three-failure watchdog after smoke/benchmark checks.
bash ./deploy_qwen38_27b_dflash2.sh --watchdog
```
