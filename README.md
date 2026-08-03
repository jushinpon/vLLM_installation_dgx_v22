# DGX Spark vLLM v0.22.0 — cluster195 Deployment

vLLM v0.22.0 inference serving system for **DGX Spark (GB10, aarch64)**.  
Model: `Qwen/Qwen3.6-27B-FP8` (default, FP8 quantized dense model).

Compatibility note: operational script and watchdog filenames still contain
`qwen35b` so existing cron entries and administrator commands keep working.
Their deployment defaults now point to Qwen3.6-27B-FP8.
**Nginx gateway** on master `:9000` — auth, rate limiting, proxying.  
Backend vLLM on `node13:8000`.

---

## Quick Reference

| Component | Host | Port | Config Dir |
|-----------|------|------|------------|
| Gateway (nginx) | master (cluster195) | 9000 | `/etc/nginx/conf.d/vllm-gateway.conf` |
| Backend (vLLM) | node13 | 8000 | `/local_opt/vllm-service-qwen35b/` |
| Install root | node13 | — | `/local_opt/vllm-install/` |
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
├── run_model_benchmarks.sh                   # Model benchmark runner
├── run_vllm_sweep.sh                         # Parameter sweep
├── continue_sweep.sh                         # Sweep continuation
├── nemotron_param_sweep.sh                   # Nemotron sweep
├── opencode_quality_ab.sh                    # A/B quality test
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

After cloning this repo on the master node, use the bootstrap wrapper for a new
cluster. It copies the repo to the backend node, installs vLLM, downloads the
Qwen3.6 27B FP8 model, deploys the backend and nginx gateway, and installs
the cron watchdog.

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
6. Verify gateway, backend model name, 65K shared-service context, and watchdog log.
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

Default production settings used by the bootstrap:

```text
model_id=/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8
served_model_name=qwen3.6-27b-fp8
gpu_memory_utilization=0.85
max_model_len=65536
max_num_batched_tokens=32768
max_num_seqs=10
thinking=enabled
language_model_only=false
limit_mm_per_prompt={"image":4}
speculative_method=qwen3_next_mtp
num_speculative_tokens=3
performance_mode=throughput
optimization_level=2
gateway_port=9000
watchdog=enabled
```

These defaults were measured on node13 with fixed 256-token outputs:

| Load | Text, thinking off | Text, thinking on | 1 image, thinking on |
|------|-------------------:|------------------:|---------------------:|
| 1 request | 21.96 tok/s | 17.02 tok/s | 15.71 tok/s |
| 4 concurrent requests | 69.55 tok/s | 64.59 tok/s | 62.80 tok/s |
| 10 concurrent requests | 161.61 tok/s | 134.07 tok/s | 128.51 tok/s |

Three additional 10-user runs with 512 output tokens measured 171.18, 173.59,
and 169.91 aggregate tok/s with zero request errors. Multimodal support is
enabled for at most four images per prompt. Merely enabling the image pipeline
did not reduce single-user text throughput; processing an actual image adds
encoder latency. Thinking improves reasoning quality but generates hidden
reasoning tokens and reduces output throughput.

Use `--dry-run` first when adapting to a new cluster name or backend hostname:

```bash
bash bootstrap_new_cluster_v022_qwen35b.sh --full-install \
  --backend-host=node13 \
  --dry-run
```

After bootstrap, verify the deployment:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl status
curl -s http://127.0.0.1:9000/healthz
ssh node13 curl -s http://127.0.0.1:8000/v1/models
tail -20 /var/log/vllm_qwen35b_watchdog.log
```

Expected state:

- Gateway is active on master port `9000`.
- Backend `node13:8000` returns model `qwen3.6-27b-fp8`.
- `/v1/models` reports `max_model_len: 65536`.
- Watchdog log shows `PROBE_OK`.

If Hermes Desktop or another OpenAI-compatible client mis-detects the model as
32K context, set that client's model context length explicitly to `65536`.

### 1. Install vLLM on backend (node13)

```bash
ssh node13
bash ./install_vllm-v022.sh
```

Installs:
- System deps (gcc, python3.12-dev, openssl, curl, etc.)
- Python venv at `/local_opt/vllm-install/.vllm`
- vLLM v0.22.0 from source (git clone + pip install)
- `vllm-nccl` + PyTorch

Takes ~20 min on DGX Spark (CPU compilation).

### 2. Download model

Edit `download_model_on_backend_v022_qwen35b.pl` to set the desired HuggingFace model ID, then:

```bash
perl ./download_model_on_backend_v022_qwen35b.pl
```

Downloads model to `/local_opt/vllm-models/<model-name>/`.

### 3. Install nginx gateway (master)

```bash
perl ./install_nginx.sh
```

Or use the deploy script directly:

```bash
perl ./deploy_nginx_gateway_v022_qwen35b.pl setup
```

This installs nginx, opens port 9000 in firewalld, enables SELinux network connect, and generates the initial config.

---

## Deploy

### Full deployment (backend + gateway)

```bash
cd vLLM_installation_dgx_v22/
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all \
  --gpu-memory-utilization=0.85 \
  --max-model-len=65536 \
  --max-num-seqs=10 \
  --max-num-batched-tokens=32768 \
  --tool-call-parser=qwen3_coder \
  --reasoning-parser=qwen3 \
  --default-chat-template-kwargs='{"enable_thinking": true}' \
  --no-language-model-only \
  --limit-mm-per-prompt='{"image":4}' \
  --speculative-method=qwen3_next_mtp \
  --num-speculative-tokens=3 \
  --performance-mode=throughput \
  --optimization-level=2 \
  --max-concurrent-per-student=6 \
  --rpm-limit=120 \
  --client-timeout=300 \
  --downstream-timeout=600 \
  --request-hard-timeout=900
```

This:
1. SSHes into **node13** and restarts vLLM with the given parameters
2. Writes `gateway_config.json` on master
3. Regenerates nginx config and reloads

Optionally include `--with-cleanup` and/or `--with-watchdog` to also run master node
cleanup and install the generation watchdog as part of the deployment:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all \
  --gpu-memory-utilization=0.85 --max-model-len=65536 \
  --with-cleanup --with-watchdog
```

### Backend only

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --backend-port=8000 \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8 \
  --served-model-name=qwen3.6-27b-fp8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=65536 \
  --max-num-seqs=10 \
  --max-num-batched-tokens=32768 \
  --tool-call-parser=qwen3_coder \
  --reasoning-parser=qwen3 \
  --default-chat-template-kwargs='{"enable_thinking": true}' \
  --no-language-model-only \
  --limit-mm-per-prompt='{"image":4}' \
  --speculative-method=qwen3_next_mtp \
  --num-speculative-tokens=3 \
  --performance-mode=throughput \
  --optimization-level=2
```

### Gateway only (skip backend restart)

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all --skip-backend
```

---

## Management

### Nginx gateway

```bash
# Install / setup
perl deploy_nginx_gateway_v022_qwen35b.pl setup

# Lifecycle
perl deploy_nginx_gateway_v022_qwen35b.pl start|stop|restart|reload|status
```

Or via the orchestrator:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl gateway-start|stop|restart|status
```

### Students

```bash
# Add
perl deploy_nginx_gateway_v022_qwen35b.pl add-student --student-id=student1
# With custom token:
perl deploy_nginx_gateway_v022_qwen35b.pl add-student --student-id=student1 --token=mytoken123

# List
perl deploy_nginx_gateway_v022_qwen35b.pl list-students

# Remove
perl deploy_nginx_gateway_v022_qwen35b.pl remove-student --student-id=student1

# Set limits
perl deploy_nginx_gateway_v022_qwen35b.pl set-student-limits --student-id=student1 --rpm-limit=60
```

Or via orchestrator:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl add-student --student-id=student1
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl list-students
```

### Token Management and Secret Safety

Student API tokens live on the master in:

```text
/local_opt/lab-vllm-gateway/config/students_tokens.json
```

Rules:

- Never commit real Bearer tokens, student tokens, or Telegram bot tokens.
- Do not hardcode API keys inside benchmark scripts.
- Use environment variables for local tests and benchmark runs.
- If GitGuardian or GitHub reports a leaked token, rotate that student token
  immediately, reload nginx, update the affected client `.env`, and verify the
  old token returns `401`.

Typical rotation flow:

```bash
perl deploy_nginx_gateway_v022_qwen35b.pl remove-student --student-id=jsp
perl deploy_nginx_gateway_v022_qwen35b.pl add-student --student-id=jsp
perl deploy_nginx_gateway_v022_qwen35b.pl list-students
nginx -t && systemctl reload nginx
```

Then update clients that use the old token, for example Hermes Desktop's
`OPENAI_API_KEY`, without writing the token into this git repo.

### Status

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl status
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl show
```

### Master cleanup & watchdog

```bash
# Fix /etc/hosts, disable slurmd and PCP services
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl master-cleanup

# Install generation watchdog (cron every 2 min, restart after 3 failures)
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl install-watchdog

# Remove watchdog cron + logrotate
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl uninstall-watchdog
```

### Shared production profile and planned restarts

The current cluster195 shared-service profile is `max-model-len=65536`,
`max-num-batched-tokens=32768`, `max-num-seqs=10`, and
`gpu-memory-utilization=0.85`. It preserves capacity for concurrent Hermes
and Telegram users. Use 131072 only for an explicitly scheduled,
lower-concurrency long-context task.

The watchdog runs every two minutes and checks `/health`, `/v1/models`, and a
real non-thinking chat completion. It restarts only after three consecutive
failures and has a 15-minute restart cooldown. The manager writes a master-
side maintenance marker before a deliberate backend start or restart. During
the model-load window watchdog probes log `PROBE_SKIPPED maintenance_active`
and reset the failure count, preventing a second restart from racing the
planned one. A stale marker is cleared after 25 minutes.

Always restart through the manager, not by invoking the backend deployer
directly:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart
```

---

## Backend vLLM Parameters

All parameters are passed via `--name=value` to the orchestrator's `apply-all` or `backend-restart` commands.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--model-id` | `/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8` | Model path or HF ID |
| `--served-model-name` | `qwen3.6-27b-fp8` | Model name exposed by API |
| `--gpu-memory-utilization` | `0.85` | Fraction of GPU memory for KV cache |
| `--max-model-len` | `65536` | Maximum context length for the shared service |
| `--max-num-seqs` | `10` | Max concurrent sequences |
| `--max-num-batched-tokens` | `32768` | Max scheduler tokens per batch |
| `--reasoning-parser` | `qwen3` | Reasoning parser for chain-of-thought |
| `--tool-call-parser` | `qwen3_coder` | Tool call format parser |
| `--default-chat-template-kwargs` | `{"enable_thinking": true}` | Enable Qwen thinking by default |
| `--enable-thinking` | on | Keep Qwen reasoning/thinking output enabled |
| `--disable-thinking` | off | Disable thinking/reasoning in output |
| `--language-model-only` | off | Optional text-only mode |
| `--limit-mm-per-prompt` | `{"image":4}` | Allow at most four images per prompt |
| `--speculative-method` | `qwen3_next_mtp` | Qwen MTP speculative decoding |
| `--num-speculative-tokens` | `3` | Draft tokens per decode step |
| `--performance-mode` | `throughput` | Optimize aggregate throughput |
| `--optimization-level` | `2` | Validated vLLM compile optimization |
| `--vllm-allow-long-max-model-len` | off | Override model's max position embeddings |

---

## Gateway Parameters (written to `gateway_config.json`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--max-concurrent-per-student` | `6` | Max simultaneous requests per student |
| `--rpm-limit` | `120` | Requests per minute per student |
| `--client-timeout` | `300` | Client connection timeout (seconds) |
| `--downstream-timeout` | `600` | Backend response timeout |
| `--request-hard-timeout` | `900` | Absolute request timeout |

---

## Student API (for users)

```
Base URL: http://<master-ip>:9000/v1
Model:    qwen3.6-27b-fp8
API key:  <student-token>
```

### Example (curl)

```bash
curl http://<gateway-ip>:9000/v1/chat/completions \
  -H "Authorization: Bearer <student-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b-fp8",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<gateway-ip>:9000/v1",
    api_key="<student-token>"
)

response = client.chat.completions.create(
    model="qwen3.6-27b-fp8",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)
```

---

## Testing

### Smoke test (backend)

```bash
bash ./smoke_test_vllm_v022_qwen35b_a3b.sh
```

### Gateway health

```bash
curl http://127.0.0.1:9000/healthz
```

### Backend health

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-smoke
```

### Process status

```bash
perl ./test_vllm_ps_v022_qwen35b_a3b.pl
```

---

## Benchmarking

Benchmark scripts read the gateway token from `VLLM_API_KEY`.
Set it in the shell before running benchmarks:

```bash
export VLLM_API_KEY='<student-token>'
```

```bash
# Token rate
perl benchmark_vllm_token_rate_v022_qwen35b.pl

# Model benchmarks
bash run_model_benchmarks.sh

# Parameter sweep
bash run_vllm_sweep.sh
bash continue_sweep.sh

# Nemotron sweep
bash nemotron_param_sweep.sh

# A/B quality test
bash opencode_quality_ab.sh
```

---

## Infrastructure Paths

### Backend (node13)

```
/local_opt/vllm-install/
  ├── .vllm/          ← Python venv (vLLM 0.22.0)
  └── vllm/           ← git clone tag v0.22.0

/local_opt/vllm-service-qwen35b/
  ├── vllm.pid        ← PID file
  └── vllm.log        ← vLLM server log

/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8/   ← Model weights
/local_opt/vllm-cache/                               ← Torch compile cache
/local_opt/hf-vllm/                                  ← HuggingFace cache
/local_opt/tmp-vllm/                                 ← Temp
```

### Gateway (master)

```
/etc/nginx/conf.d/vllm-gateway.conf    ← Nginx config (generated)

/local_opt/lab-vllm-gateway/
  ├── config/gateway_config.json       ← Runtime config
  ├── config/students_tokens.json      ← Student tokens
  ├── logs/access.log                  ← Access log
  ├── logs/gateway.log                 ← Legacy Perl gateway log
  └── run/gateway.pid                  ← Legacy PID
```

---

## Recommended Context Length Settings

| Context | `max-model-len` | `max-num-seqs` | `gpu-memory-utilization` |
|---------|----------------|---------------|--------------------------|
| 64K current production (10-user) | 65536 | 10 | 0.85 |
| 262K multimodal fallback | 262144 | 4 | 0.85 |
| 64K lower-memory fallback | 65536 | 8 | 0.75 |
| 32K conservative fallback | 32768 | 16 | 0.70 |
| 128K scheduled single-user fallback | 131072 | 4 | 0.85 |
| 320K | 327680 | 4 | 0.85 (needs `--vllm-allow-long-max-model-len`) |
| 520K | 520000 | 2 | 0.85 (needs `--vllm-allow-long-max-model-len`) |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Gateway 401 | Invalid token — check `list-students` |
| Gateway 502 / 504 | Backend unreachable — check `backend-smoke` |
| Backend won't start | Check `/local_opt/vllm-service-qwen35b/vllm.log` |
| nginx config error | `nginx -t` to test config |
| SELinux blocking | `getsebool httpd_can_network_connect` |
| vLLM OOM | Reduce `--gpu-memory-utilization` or `--max-model-len` |
| Student can't connect | Token not in `students_tokens.json` |
| Gateway access log | `/var/log/nginx/vllm-gateway-access.log` |
| Gateway error log | `/var/log/nginx/vllm-gateway-error.log` |

---

## Legacy Perl Gateway

The old Perl prefork gateway has been moved to `Perl_gateway/`.  
To use it instead of nginx:

```bash
cd vLLM_installation_dgx_v22/Perl_gateway
perl deploy_lab_vllm_gateway_v022_qwen35b.pl setup-master --backend-host=node13 --backend-port=8000
perl deploy_lab_vllm_gateway_v022_qwen35b.pl start
```

**Note**: The Perl gateway uses a fork-based prefork model that does not scale well beyond a few concurrent users. Use the nginx gateway for production.

---

## Notes

- DGX Spark (aarch64, GB10 GPU, NVIDIA DRIVER 580)
- vLLM 0.22.0 compiled from source for aarch64
- Model: Qwen3.6-27B-FP8 (FP8 quantized dense model)
- Backend uses `--enable-chunked-prefill` + `--enable-prefix-caching`
- The legacy `--moe-backend=triton` launcher option is retained for compatibility;
  it is not used by this dense model.
- nginx gateway uses `map` for token auth and `limit_req_zone` for rate limiting
- **fail2ban** is installed on the master for SSH brute-force protection

## Production stability setup

After installing or reinstalling vLLM, apply the production stability patch in one command:

```bash
cd vLLM_installation_dgx_v22/
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all --with-cleanup --with-watchdog
```

This runs:

1. **master-cleanup** — Fixes `/etc/hosts` (FQDN), disables `slurmd` and 8 PCP systemd units.
2. **install-watchdog** — Installs a cron-based generation watchdog that checks `/health`, `/v1/models`, and a real `/v1/chat/completions` smoke test every 2 minutes. After 3 consecutive generation failures, it restarts the node13 backend (with backups).
3. **backend-restart** — Restarts vLLM with the current parameters.
4. **gateway-setup** — Regenerates nginx config and reloads.

Individual commands:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl master-cleanup
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl install-watchdog
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl uninstall-watchdog
```

See `patch_20260630/README.md` for full details, including watchdog behavior, log paths, state files, backup locations, and recovery notes.

See `patch_20260630/QWEN36_27B_DEPLOYMENT_20260725.md` for the validated
Qwen3.6-27B-FP8 deployment, performance results, 10-student load test, and
rollback procedure.

## Crash Forensics

The production deployment records enough metadata to investigate a vLLM
failure without storing prompts or API keys.

- Gateway requests: `/var/log/nginx/vllm-gateway-access.log`
  - fields include timestamp, authenticated `student` ID, client IP, Hermes
    mode, endpoint, status, request size, request time, and upstream time.
  - request bodies and `Authorization` values are never logged.
- Gateway upstream errors: `/var/log/nginx/vllm-gateway-error.log`
- Watchdog history: `/var/log/vllm_qwen35b_watchdog.log`
- Master incident bundles: `/var/lib/vllm_qwen35b_watchdog/forensics/`
- Node13 incident bundles:
  `/local_opt/vllm-service-qwen35b/hosts/node13/forensics/`
- Previous vLLM server runs:
  `/local_opt/vllm-service-qwen35b/hosts/node13/logs/archive/`

Each failed watchdog generation probe creates a matching incident ID on the
master and Node13. The bundle includes gateway tails, vLLM log tail, GPU
allocation/process state, memory/process state, and the last 30 minutes of
kernel and system journal. Use the same incident ID to correlate a student
request with a GPU OOM, upstream timeout, or vLLM process exit.

Forensic bundles and archived vLLM server logs are retained for 60 days.

---

## AI Agent 操作指南

本指南供 AI Agent（如 Hermes Agent）讀取後，可獨立完成 vLLM 部署、管理、疑難排解等任務。

### 部署新叢集（一鍵安裝）

```bash
# 在 master node 上執行
cd /path/to/vLLM_installation_dgx_v22

# 先預覽（dry run）
bash bootstrap_new_cluster_v022_qwen35b.sh --full-install --backend-host=node13 --dry-run

# 實際安裝
bash bootstrap_new_cluster_v022_qwen35b.sh --full-install --backend-host=node13
```

### 僅套用配置（已有 vLLM + 模型）

```bash
bash bootstrap_new_cluster_v022_qwen35b.sh --apply-only --backend-host=node13
```

### 檢查系統狀態

```bash
# 完整狀態
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl status

# 後端煙霧測試
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-smoke

# 健康檢查
curl -s http://127.0.0.1:9000/healthz

# 查看 watchdog 日誌
tail -20 /var/log/vllm_qwen35b_watchdog.log
```

### 後端參數調整並重啟

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=65536 \
  --max-num-batched-tokens=32768 \
  --max-num-seqs=10
```

### 管理學生帳號

```bash
# 新增學生
perl deploy_nginx_gateway_v022_qwen35b.pl add-student --student-id=student1

# 列出所有學生
perl deploy_nginx_gateway_v022_qwen35b.pl list-students

# 移除學生
perl deploy_nginx_gateway_v022_qwen35b.pl remove-student --student-id=student1

# 設定限速
perl deploy_nginx_gateway_v022_qwen35b.pl set-student-limits --student-id=student1 --rpm-limit=60
```

### 疑難排解流程

```
症狀 → 檢查 → 解決
Gateway 401 → perl deploy_nginx_gateway_v022_qwen35b.pl list-students → 檢查 token 是否有效
Gateway 502/504 → perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-smoke → 後端是否運行
後端無法啟動 → cat /local_opt/vllm-service-qwen35b/vllm.log → 檢查 vLLM 錯誤
nginx config error → nginx -t → 修復 config
SELinux blocking → getsebool httpd_can_network_connect → setsebool -P httpd_can_network_connect on
vLLM OOM → 降低 --gpu-memory-utilization 或 --max-model-len
客戶無法連線 → 檢查 student token 在 students_tokens.json 中
```
