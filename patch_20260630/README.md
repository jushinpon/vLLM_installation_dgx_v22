# patch_20260630 - vLLM stability and master-node cleanup notes

This folder records the configuration work performed on 2026-06-30 for the lab vLLM deployment.

Main target:

- Master node: `cluster195` / `master`
- vLLM backend node: `node13`
- vLLM backend port: `8000`
- nginx gateway port on master: `9000`
- Served model: `qwen3.6-35b-a3b-fp8`
- Manager directory: `/home/dgx-spark-vllm-setup-v022`

## What was changed

### 1. Master node cleanup

The master node is not a compute node, so `slurmd` was disabled and its failed state cleared.

Broken PCP services/timers were disabled because they were producing repeated system errors and were not needed for the vLLM service:

- `pmcd`
- `pmlogger`
- `pmlogger_daily.timer`
- `pmlogger_check.timer`
- `pmlogger_daily-poll.timer`

The master host entry in `/etc/hosts` was changed so `hostname -f` resolves:

```text
<master-ip> master.localdomain master
```

Backup from that operation:

```text
/root/codex_backups_cluster195/20260630_182948
```

Related script in this patch folder:

```text
scripts/01_master_node_cleanup_cluster195.sh
```

### 2. vLLM backend was restarted

The failure mode found on node13 was:

- `/health` returned OK.
- `/v1/models` returned OK.
- Real `/v1/chat/completions` generation timed out.
- `VLLM::EngineCore` was using high GPU compute.
- The engine log showed running requests and later `0.0 tokens/s` throughput.

Therefore, the backend was alive but generation was wedged. The manager health check was too shallow because it only checked readiness endpoints.

Related script:

```text
scripts/02_restart_vllm_backend_current.sh
```

### 3. vLLM was changed to a safer text-only 131k context configuration

The manager default was changed from a very large context to:

```text
max_model_len = 131072
```

Image/multimodal was disabled for stability. The live process now uses:

```text
--max-model-len 131072
--language-model-only
```

It no longer passes:

```text
--limit-mm-per-prompt {"image":1}
```

Other key parameters kept:

```text
--gpu-memory-utilization 0.85
--max-num-batched-tokens 16384
--max-num-seqs 4
--reasoning-parser qwen3
--tool-call-parser qwen3_coder
--disable-thinking
```

Backup of the manager before editing:

```text
/root/codex_backups_vllm/20260630_190302/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl
```

Related script:

```text
scripts/03_set_vllm_131k_textonly_and_restart.sh
```

### 4. Watchdog was installed

The watchdog checks real generation, not only `/health`.

Installed files:

```text
/usr/local/sbin/vllm_qwen35b_watchdog.sh
/etc/cron.d/vllm_qwen35b_watchdog
/etc/logrotate.d/vllm_qwen35b_watchdog
```

Copies of the installed files are stored here:

```text
installed_copies/vllm_qwen35b_watchdog.sh
installed_copies/vllm_qwen35b_watchdog.cron
installed_copies/vllm_qwen35b_watchdog.logrotate
```

The cron job runs every 2 minutes:

```text
*/2 * * * * root /usr/local/sbin/vllm_qwen35b_watchdog.sh
```

The watchdog does:

1. SSH from master to `node13`.
2. Check `http://127.0.0.1:8000/health`.
3. Check `http://127.0.0.1:8000/v1/models`.
4. Run a real `/v1/chat/completions` request asking the model to reply `OK`.
5. If the generation smoke test succeeds, reset failure count to 0.
6. If the generation smoke test fails 3 times in a row, restart only the node13 backend through the manager.
7. Use a lock file to avoid overlapping watchdog runs.
8. Use a 15-minute cooldown to avoid repeated restarts while the model is loading.

State/log files:

```text
/var/log/vllm_qwen35b_watchdog.log
/var/lib/vllm_qwen35b_watchdog/fail_count
/var/lib/vllm_qwen35b_watchdog/last_restart_epoch
/run/vllm_qwen35b_watchdog.lock
```

Backup from watchdog installation:

```text
/root/codex_backups_vllm_watchdog/20260630_191403
```

Related scripts:

```text
scripts/04_install_vllm_watchdog_cron.sh
scripts/05_verify_vllm_watchdog.sh
```

## Current verified status after patch

As verified after installation:

```text
/v1/models -> qwen3.6-35b-a3b-fp8, max_model_len=131072
/health -> HTTP 200
watchdog generation probe -> PROBE_OK content=OK
fail_count -> 0
```

The cron-triggered watchdog was observed writing:

```text
[2026-06-30 19:16:02 CST] PROBE_OK elapsed_sec=0.11 content=OK
```

## How to manually check vLLM

Run on master:

```bash
/home/dgx-spark-vllm-setup-v022/patch_20260630/scripts/06_check_live_vllm_config.sh
```

Expected:

```text
qwen3.6-35b-a3b-fp8 131072
health_http=200
process command contains --max-model-len 131072 and --language-model-only
```

## How to manually run watchdog once

Run on master:

```bash
/usr/local/sbin/vllm_qwen35b_watchdog.sh
tail -20 /var/log/vllm_qwen35b_watchdog.log
cat /var/lib/vllm_qwen35b_watchdog/fail_count
```

Expected when healthy:

```text
PROBE_OK elapsed_sec=... content=OK
0
```

## How automatic restart works

If vLLM is reachable but generation is stuck, watchdog failures accumulate:

```text
PROBE_FAIL count=1/3
PROBE_FAIL count=2/3
PROBE_FAIL count=3/3
```

At 3 consecutive failures, the watchdog runs:

```bash
cd /home/dgx-spark-vllm-setup-v022
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --backend-port=8000 \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
  --served-model-name=qwen3.6-35b-a3b-fp8 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=131072 \
  --max-num-batched-tokens=16384 \
  --max-num-seqs=4 \
  --tool-call-parser=qwen3_coder \
  --reasoning-parser=qwen3 \
  --disable-thinking
```

The restart command is text-only because it does not include `--no-language-model-only` or `--limit-mm-per-prompt`.

## How to disable watchdog

Run on master:

```bash
mv /etc/cron.d/vllm_qwen35b_watchdog /etc/cron.d/vllm_qwen35b_watchdog.disabled
```

To re-enable:

```bash
mv /etc/cron.d/vllm_qwen35b_watchdog.disabled /etc/cron.d/vllm_qwen35b_watchdog
```

## How to restore the previous manager script

If needed, restore the backup:

```bash
cp -a /root/codex_backups_vllm/20260630_190302/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl \
  /home/dgx-spark-vllm-setup-v022/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl
```

Then restart backend if required.

## Notes

- The watchdog intentionally tests node13 directly through `127.0.0.1:8000`; it does not require student gateway tokens.
- nginx student token configuration was not changed.
- Gateway health endpoint is `/healthz`, not `/health`.
- `/v1/models` on the public gateway correctly returns 401 without a bearer token.
- If 10 students use Hermes agents concurrently, the next stability improvement should be request/concurrency limiting at the gateway or manager layer.
