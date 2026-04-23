#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — baseline-vs-GPU test harness for the 2026-04-23 migration.
#
# Fires N synthetic alerts at the triage service, waits for each verdict
# to land in /decisions, and prints: count, median/p95/p99 time-to-verdict,
# verdict distribution, and any timeouts/errors.
#
# USAGE:
#   TARGET=http://<gpu-eip>:8090 N=10 ./benchmark.sh
#
#   # To run against the k3s baseline for comparison:
#   TARGET=http://<k3s-eip>:30080 PATH_PREFIX=/triage N=10 ./benchmark.sh
#
# ENV VARS:
#   TARGET        required. Base URL of the triage service (no trailing /).
#   PATH_PREFIX   optional. Prefix for webhook + decisions endpoints
#                 (empty for GPU box; "/triage" for k3s NodePort). Default: ""
#   N             optional. Number of alerts to fire. Default: 10.
#   INTER_SECS    optional. Seconds between webhook POSTs. Default: 2.
#   MAX_WAIT_SECS optional. Per-alert max wait for verdict. Default: 900.
#   OUT_DIR       optional. Directory for per-run CSV + raw verdicts.
#                 Default: ./bench-$(date +%Y%m%d-%H%M%S)
#
# WHAT GETS COMPARED:
#   The SAME alert payload is used regardless of target, so apples-to-apples.
#   The alert is a synthetic "BackendHigh5xxRate" pattern with a fresh
#   startsAt stamp (now - 2 min) so the context window anchors correctly.
# =============================================================================

set -euo pipefail

: "${TARGET:?TARGET env var is required (e.g. http://52.x.x.x:8090)}"

PATH_PREFIX="${PATH_PREFIX:-}"
N="${N:-10}"
INTER_SECS="${INTER_SECS:-2}"
MAX_WAIT_SECS="${MAX_WAIT_SECS:-900}"
OUT_DIR="${OUT_DIR:-./bench-$(date +%Y%m%d-%H%M%S)}"

WEBHOOK="${TARGET}${PATH_PREFIX}/webhook/grafana"
DECISIONS="${TARGET}${PATH_PREFIX}/decisions"

mkdir -p "$OUT_DIR"
csv="${OUT_DIR}/results.csv"
echo "seq,alert_name,started_at,verdict_at,elapsed_seconds,verdict,confidence" > "$csv"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
log "Target:       $TARGET"
log "Webhook:      $WEBHOOK"
log "Decisions:    $DECISIONS"
log "Alerts:       $N  (one every ${INTER_SECS}s)"
log "Max wait:     ${MAX_WAIT_SECS}s per alert"
log "Results CSV:  $csv"
log ""
log "Target /health:"
curl -sSf --max-time 5 "${TARGET}${PATH_PREFIX}/health" >/dev/null || {
  log "FAIL: target /health not reachable"; exit 1;
}
log "  OK"
log ""

# -----------------------------------------------------------------------------
# Fire N alerts
# -----------------------------------------------------------------------------
for i in $(seq 1 "$N"); do
  alert_name="BenchHigh5xxRate_${i}_$(date +%s)"
  started_at="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%S.000Z)"

  payload=$(cat <<EOF
{
  "receiver": "triage-service-webhook",
  "status": "firing",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "${alert_name}",
      "severity": "critical",
      "service": "spring-boot-app",
      "k8s_namespace_name": "default",
      "k8s_pod_name": "bench-pod"
    },
    "annotations": {
      "summary": "Benchmark synthetic alert ${i}/${N}",
      "description": "Synthetic 5xx surge for GPU migration benchmark."
    },
    "startsAt": "${started_at}",
    "fingerprint": "bench-${alert_name}"
  }]
}
EOF
)
  t0="$(date +%s)"
  post_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    -H "Content-Type: application/json" \
    -X POST "$WEBHOOK" -d "$payload")

  if [[ "$post_status" != "202" && "$post_status" != "200" ]]; then
    log "[$i/$N] POST FAILED (HTTP $post_status) — skipping"
    printf '%d,%s,%s,,,POST_FAIL,\n' "$i" "$alert_name" "$started_at" >> "$csv"
    continue
  fi
  log "[$i/$N] POSTED $alert_name (HTTP $post_status) — polling for verdict..."

  # Poll /decisions until the verdict for this alert_name appears.
  verdict=""
  confidence=""
  t_end=$((t0 + MAX_WAIT_SECS))
  while (( $(date +%s) < t_end )); do
    sleep 5
    if decision_line=$(curl -sS --max-time 10 \
        "${DECISIONS}?alert_name=${alert_name}&limit=1" \
        | grep -m1 '"decision"'); then
      verdict=$(echo "$decision_line" | sed -E 's/.*"decision": *"([^"]+)".*/\1/' | head -1)
      confidence=$(curl -sS --max-time 10 \
        "${DECISIONS}?alert_name=${alert_name}&limit=1" \
        | grep -m1 '"confidence"' \
        | sed -E 's/.*"confidence": *([0-9.]+).*/\1/' | head -1)
      break
    fi
  done

  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  verdict_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$verdict" ]]; then
    log "[$i/$N] TIMEOUT after ${elapsed}s"
    printf '%d,%s,%s,%s,%d,TIMEOUT,\n' "$i" "$alert_name" "$started_at" "$verdict_at" "$elapsed" >> "$csv"
  else
    log "[$i/$N] VERDICT: $verdict (conf=$confidence) in ${elapsed}s"
    printf '%d,%s,%s,%s,%d,%s,%s\n' "$i" "$alert_name" "$started_at" "$verdict_at" "$elapsed" "$verdict" "$confidence" >> "$csv"
  fi

  sleep "$INTER_SECS"
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log ""
log "=== SUMMARY ==="
total=$(tail -n +2 "$csv" | wc -l)
ok=$(tail -n +2 "$csv" | awk -F, '$6!="POST_FAIL" && $6!="TIMEOUT" {n++} END{print n+0}')
timeouts=$(tail -n +2 "$csv" | awk -F, '$6=="TIMEOUT" {n++} END{print n+0}')
fails=$(tail -n +2 "$csv" | awk -F, '$6=="POST_FAIL" {n++} END{print n+0}')

log "Alerts fired:   $total"
log "Verdicts:       $ok"
log "Timeouts:       $timeouts"
log "POST failures:  $fails"

if (( ok > 0 )); then
  log ""
  log "Time-to-verdict (seconds):"
  tail -n +2 "$csv" | awk -F, '$6!="POST_FAIL" && $6!="TIMEOUT" {print $5}' \
    | sort -n | awk '
      { a[NR]=$1 }
      END {
        n=NR; if (n==0) exit
        print "  min:     " a[1]
        print "  p50:     " a[int(n*0.50+0.5)]
        print "  p95:     " a[int(n*0.95+0.5)]
        print "  p99:     " a[int(n*0.99+0.5)]
        print "  max:     " a[n]
        sum=0; for (i=1;i<=n;i++) sum+=a[i]
        printf  "  mean:    %.1f\n", sum/n
      }'
  log ""
  log "Verdict distribution:"
  tail -n +2 "$csv" | awk -F, '$6!="POST_FAIL" && $6!="TIMEOUT" {print $6}' \
    | sort | uniq -c | sort -rn | awk '{printf "  %s %s\n", $2, $1}'
fi

log ""
log "Raw CSV: $csv"
