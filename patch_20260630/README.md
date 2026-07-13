# vLLM Lab Deployment Guide

## Architecture

| Component | Host | Details |
|-----------|------|---------|
| **vLLM backend** | `node13` | Port 8000, model `qwen3.6-35b-a3b-fp8` |
| **nginx gateway** | `master` (cluster195) | Port 9000, model routing + student auth |
| **Manager** | `master` | `/home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl` |

---

## 1. Prerequisites (master)

Ensure these run on the master node:

```bash
sudo -i
ssh-copy-id root@node13   # key-based SSH for backend actions
yum install -y nginx perl-JSON-PP perl-File-Path
```

The gateway is deployed from the master to itself, so it also needs port 9000 open. No other setup is needed on `node13` — the manager handles everything via SSH.

---

## 2. Master node cleanup

The master is not a compute node. Run once to disable unnecessary services:

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl master-cleanup
```

This:

- Fixes `/etc/hosts` so `<master-ip>` resolves as `master.localdomain master` (idempotent).
- Disables `slurmd` and resets its failed state.
- Disables 8 PCP systemd units (`pmcd`, `pmlogger`, etc.).
- Backs up modified files to `/root/codex_backups_cluster195/<timestamp>/`.

---

## 3. Deploy vLLM backend

Restart (or start) the vLLM API server on `node13`:

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart
```

Default arguments are embedded in the script. Override as needed:

```bash
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
  --served-model-name=qwen3.6-35b-a3b-fp8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=262144 \
  --max-num-batched-tokens=16384 \
  --max-num-seqs=4 \
  --reasoning-parser=qwen3 \
  --tool-call-parser=qwen3_coder \
  --disable-thinking
```

Other backend actions:

| Command | Description |
|---------|-------------|
| `backend-start` | Start backend |
| `backend-stop` | Stop backend |
| `backend-status` | Show backend status |
| `backend-smoke` | Quick health check |
| `force-kill-backend` | Kill all vLLM processes on node13 |

---

## 4. Deploy nginx gateway

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl gateway-setup
```

This installs nginx (if missing) and writes the gateway config to `/local_opt/lab-vllm-gateway/config/gateway_config.json`. Default gateway port is `9000`.

Gateway actions:

| Command | Description |
|---------|-------------|
| `gateway-start` | Start gateway |
| `gateway-stop` | Stop gateway |
| `gateway-restart` | Restart gateway |
| `gateway-reload` | Reload nginx config |
| `gateway-status` | Show gateway status |

Student management:

| Command | Description |
|---------|-------------|
| `add-student --student-id=ID` | Add student with auto-generated API token |
| `remove-student --student-id=ID` | Remove a student |
| `set-student-limits --student-id=ID` | Update rate limits |
| `list-students` | List all students and tokens |

---

## 5. Install watchdog

The watchdog probes real LLM generation on `node13` every 2 minutes and restarts the backend after 3 consecutive failures.

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl install-watchdog
```

Installed files:

| File | Purpose |
|------|---------|
| `/usr/local/sbin/vllm_qwen35b_watchdog.sh` | Watchdog script (SSH + Python probe) |
| `/etc/cron.d/vllm_qwen35b_watchdog` | Cron entry (`*/2 * * * *`) |
| `/etc/logrotate.d/vllm_qwen35b_watchdog` | Log rotation (weekly, 8 copies) |

Backups of any previous files go to `/root/codex_backups_vllm_watchdog/<timestamp>/`.

To remove:

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl uninstall-watchdog
```

---

## 6. Apply all (single command)

Combines cleanup + watchdog install + backend restart + gateway setup:

```bash
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all \
  --with-cleanup \
  --with-watchdog
```

Use `--skip-backend` to skip the backend restart step.

---

## 7. Verify

Run on master:

```bash
# Check gateway status
perl /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl status

# Manual watchdog run
/usr/local/sbin/vllm_qwen35b_watchdog.sh
tail -20 /var/log/vllm_qwen35b_watchdog.log

# Check failure count
cat /var/lib/vllm_qwen35b_watchdog/fail_count    # should be 0
```

Expected healthy output: `PROBE_OK elapsed_sec=0.1x content=OK`

---

## 8. Common options

| Flag | Applies to | Description |
|------|-----------|-------------|
| `--with-cleanup` | `apply-all` | Run master cleanup first |
| `--with-watchdog` | `apply-all` | Install watchdog before restart |
| `--skip-backend` | `apply-all` | Skip backend restart |
| `--model-id` | backend actions | vLLM model path |
| `--served-model-name` | backend actions | Exposed model name |
| `--gpu-memory-utilization` | backend actions | GPU memory fraction |
| `--max-model-len` | backend actions | Max context length |
| `--max-concurrent-per-student` | gateway actions | Concurrent request limit per student |
| `--rpm-limit` | gateway actions | Rate limit per student |
