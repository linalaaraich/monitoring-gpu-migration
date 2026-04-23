#!/usr/bin/env bash
# =============================================================================
# test-alert.sh — fire ONE synthetic alert at a running triage service and
# poll /decisions until a verdict lands.
#
# Run this from INSIDE the WSL2 Ubuntu shell (not PowerShell).
#
# Usage:
#   ./test-alert.sh                      # defaults: localhost:8090
#   TARGET=http://localhost:8090 ./test-alert.sh
#
# What it does:
#   1. Stamps startsAt=now-2min (so the context window covers sensible data).
#   2. POSTs sample-alert.json to /webhook/grafana.
#   3. Polls /decisions?alert_name=... every 10s for up to 15 min, printing
#      the verdict once it appears.
# =============================================================================

set -euo pipefail

TARGET="${TARGET:-http://localhost:8090}"
ALERT_NAME="LaptopSmoke_$(date +%H%M%S)"
STARTS_AT="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%S.000Z)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read sample payload + patch in the per-run alert name & startsAt.
PAYLOAD=$(python3 -c "
import json, sys
with open('${SCRIPT_DIR}/sample-alert.json') as f:
    d = json.load(f)
d['alerts'][0]['labels']['alertname'] = '${ALERT_NAME}'
d['alerts'][0]['startsAt'] = '${STARTS_AT}'
d['groupLabels']['alertname'] = '${ALERT_NAME}'
print(json.dumps(d))
")

echo "[test-alert] Target:      ${TARGET}"
echo "[test-alert] Alert name:  ${ALERT_NAME}"
echo "[test-alert] startsAt:    ${STARTS_AT}"
echo

echo "[test-alert] POSTing to ${TARGET}/webhook/grafana ..."
http_code=$(curl -sS -o /tmp/triage_resp.txt -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -X POST "${TARGET}/webhook/grafana" \
  -d "${PAYLOAD}")

if [[ "${http_code}" != "202" && "${http_code}" != "200" ]]; then
  echo "[test-alert] FAIL — webhook returned HTTP ${http_code}"
  cat /tmp/triage_resp.txt
  exit 1
fi
echo "[test-alert] OK (HTTP ${http_code}) — pipeline accepted the alert."
echo

echo "[test-alert] Polling /decisions for a verdict (15 min cap)..."
deadline=$(( $(date +%s) + 900 ))
while (( $(date +%s) < deadline )); do
  sleep 10
  resp=$(curl -sS "${TARGET}/decisions?alert_name=${ALERT_NAME}&limit=1" || true)
  if echo "${resp}" | grep -q '"decision"'; then
    echo
    echo "=========================  VERDICT  ========================="
    echo "${resp}" | python3 -m json.tool
    echo "============================================================="
    echo
    echo "Open the dashboard: ${TARGET}/dashboard"
    exit 0
  fi
  printf '.'
done

echo
echo "[test-alert] TIMEOUT — no verdict within 15 min."
echo "  Check: docker compose logs --tail=100 triage-service"
echo "  Check: docker compose logs --tail=50  ollama"
exit 1
