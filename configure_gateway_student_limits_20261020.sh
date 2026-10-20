#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NGINX_MANAGER="$ROOT/deploy_nginx_gateway_v022_qwen35b.pl"

[[ -x "$NGINX_MANAGER" ]] || { echo "Missing gateway manager: $NGINX_MANAGER" >&2; exit 1; }

# Student tokens remain in the protected runtime file.  These non-secret
# overrides make a fresh gateway deployment reproduce the production limits.
perl "$NGINX_MANAGER" set-student-limits dsh --max-concurrent=6
perl "$NGINX_MANAGER" set-student-limits hermes --max-concurrent=6
perl "$NGINX_MANAGER" set-student-limits jsp --max-concurrent=6

echo "Gateway student concurrency limits applied: dsh=6 hermes=6 jsp=6"
