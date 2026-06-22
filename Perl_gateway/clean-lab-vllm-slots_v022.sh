#!/usr/bin/env bash
set -euo pipefail

SLOT_ROOT="/local_opt/lab-vllm-gateway/run/state/student_slots"
LOG_FILE="/local_opt/lab-vllm-gateway/logs/slot-cleanup.log"

mkdir -p "$(dirname "$LOG_FILE")"

timestamp() {
    date '+%F %T'
}

if [ ! -d "$SLOT_ROOT" ]; then
    echo "$(timestamp) SLOT_ROOT not found: $SLOT_ROOT" >> "$LOG_FILE"
    exit 0
fi

checked=0
removed=0
active=0
skipped=0

while IFS= read -r -d '' slot; do
    checked=$((checked + 1))

    base="$(basename "$slot")"
    pid="${base%.slot}"

    # Only handle normal PID-style slot files, e.g. 2359001.slot
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        skipped=$((skipped + 1))
        echo "$(timestamp) skip non-PID slot: $slot" >> "$LOG_FILE"
        continue
    fi

    # If the PID still exists, this slot is active. Do not delete it.
    if kill -0 "$pid" 2>/dev/null; then
        active=$((active + 1))
        continue
    fi

    # If the PID does not exist, this slot is stale.
    echo "$(timestamp) removing stale slot: $slot" >> "$LOG_FILE"
    rm -f "$slot"
    removed=$((removed + 1))
done < <(find "$SLOT_ROOT" -type f -name "*.slot" -print0)

echo "$(timestamp) cleanup summary: checked=$checked active=$active removed=$removed skipped=$skipped" >> "$LOG_FILE"

exit 0
