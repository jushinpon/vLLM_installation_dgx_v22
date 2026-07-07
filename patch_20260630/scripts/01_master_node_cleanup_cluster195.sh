#!/usr/bin/env bash
set -u

# Purpose:
#   Cleanup cluster195 master-node errors:
#   - give master a resolvable FQDN in /etc/hosts
#   - disable slurmd on the master node because it is not a compute node
#   - disable broken PCP services/timers that were producing repeated errors
#
# Run on:
#   cluster195 master node, as root.

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="/root/codex_backups_cluster195/$ts"
mkdir -p "$backup_dir"

echo "===BACKUP_DIR==="
echo "$backup_dir"

for f in /etc/hosts /etc/hostname /etc/mail/sendmail.mc /etc/mail/sendmail.cf; do
  if [ -f "$f" ]; then
    cp -a "$f" "$backup_dir/"
    echo "backed up $f"
  fi
done

if grep -qE '^[[:space:]]*192\.168\.0\.101[[:space:]]+master([[:space:]]|$)' /etc/hosts; then
  sed -i 's/^[[:space:]]*192\.168\.0\.101[[:space:]]\+master[[:space:]]*$/<master-ip> master.localdomain master/' /etc/hosts
elif ! grep -qE '^[[:space:]]*192\.168\.0\.101[[:space:]]+.*master' /etc/hosts; then
  echo '<master-ip> master.localdomain master' >> /etc/hosts
fi

systemctl disable --now slurmd || true
systemctl reset-failed slurmd || true

for unit in \
  pmlogger.service pmlogger_daily.timer pmlogger_check.timer \
  pmlogger_daily-poll.timer pmlogger_daily-poll.service \
  pmcd.service pmie.service pmie_daily.timer pmie_check.timer; do
  systemctl disable --now "$unit" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
done

echo "===VERIFY==="
hostname -f || true
systemctl --failed --no-pager || true
