#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Verify installed vLLM watchdog, cron file, log, state, and crond status.
#
# Run on:
#   cluster195 master node, as root.

echo "===WATCHDOG_FILE==="
ls -l /usr/local/sbin/vllm_qwen35b_watchdog.sh
bash -n /usr/local/sbin/vllm_qwen35b_watchdog.sh && echo syntax_ok

echo "===CRON_FILE==="
ls -l /etc/cron.d/vllm_qwen35b_watchdog
cat /etc/cron.d/vllm_qwen35b_watchdog

echo "===LOG_FILE==="
ls -l /var/log/vllm_qwen35b_watchdog.log || true
tail -80 /var/log/vllm_qwen35b_watchdog.log 2>/dev/null || true

echo "===STATE==="
ls -la /var/lib/vllm_qwen35b_watchdog 2>/dev/null || true
for f in /var/lib/vllm_qwen35b_watchdog/*; do
  [ -f "$f" ] && echo "$f=$(cat "$f")"
done 2>/dev/null || true

echo "===CROND_STATUS==="
systemctl status crond --no-pager -l || systemctl status cron --no-pager -l || true

echo "===MANUAL_RUN==="
/usr/local/sbin/vllm_qwen35b_watchdog.sh
tail -20 /var/log/vllm_qwen35b_watchdog.log
