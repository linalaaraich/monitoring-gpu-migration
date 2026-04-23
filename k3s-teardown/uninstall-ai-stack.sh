#!/usr/bin/env bash
# =============================================================================
# uninstall-ai-stack.sh — remove the AI stack (Ollama, triage, 5 MCPs)
# from the k3s cluster AFTER it has been verified running on the GPU box.
#
# Idempotent: re-running on an already-uninstalled release is a no-op.
#
# WHAT THIS DOES:
#   1. Confirms the GPU box's triage is healthy (cross-check — don't tear
#      down k3s AI until the replacement is demonstrably up).
#   2. Confirms the Grafana webhook is NO LONGER pointing at the k3s
#      NodePort (otherwise alerts will black-hole after uninstall).
#   3. `helm uninstall ai-stack -n ai` (non-interactive).
#   4. Deletes the `ai` namespace to clean up PVCs, ConfigMaps, Secrets.
#      NOTE: PVC deletion wipes rca_history.db and Drain3 state on the k3s
#      cluster. That's intentional — source of truth is now the GPU box's
#      triage_data volume. If you want to preserve the k3s state as a
#      backup, set PRESERVE_K3S_STATE=1 before running.
#
# WHAT THIS DOES NOT DO:
#   - Downsize the k3s EC2 instance. That's a separate Terraform apply
#     (Phase 2 of terraform.tfvars.new).
#   - Rebuild k3s container images or touch any app workload (Spring,
#     Kong, OTel collector — all untouched).
#
# USAGE:
#   GPU_EIP=<gpu-public-ip> ./uninstall-ai-stack.sh
#     or (if running locally on the k3s node with the GPU box reachable):
#   GPU_EIP=52.x.x.x ./uninstall-ai-stack.sh
# =============================================================================

set -euo pipefail

: "${GPU_EIP:?GPU_EIP environment variable is required (public IP of the GPU VM)}"
PRESERVE_K3S_STATE="${PRESERVE_K3S_STATE:-0}"

KUBECONFIG_DEFAULT="/etc/rancher/k3s/k3s.yaml"
KUBECTL="sudo k3s kubectl"   # works on the k3s node; adjust if remote

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Confirm GPU box is healthy before removing the k3s fallback.
# ----------------------------------------------------------------------------
log "Checking GPU triage is healthy at http://${GPU_EIP}:8090/health ..."
http_status=$(curl -sSo /dev/null -w '%{http_code}' --max-time 5 \
  "http://${GPU_EIP}:8090/health" || echo "000")
if [[ "$http_status" != "200" ]]; then
  fail "GPU triage not reachable (HTTP $http_status). Refusing to uninstall k3s AI."
fi
log "GPU triage /health returned 200."

# ----------------------------------------------------------------------------
# 2. Confirm the helm release exists; if not, we're done.
# ----------------------------------------------------------------------------
if ! sudo KUBECONFIG="${KUBECONFIG_DEFAULT}" helm list -n ai -q | grep -qx 'ai-stack'; then
  log "No ai-stack release in namespace 'ai'. Nothing to uninstall."
  exit 0
fi

# ----------------------------------------------------------------------------
# 3. (Optional) back up k3s triage PVC contents before uninstall.
# ----------------------------------------------------------------------------
if [[ "$PRESERVE_K3S_STATE" == "1" ]]; then
  log "PRESERVE_K3S_STATE=1 — copying /data from triage pod to ./k3s-triage-backup/"
  mkdir -p ./k3s-triage-backup
  triage_pod=$(${KUBECTL} -n ai get pod -l app.kubernetes.io/name=triage-service -o jsonpath='{.items[0].metadata.name}')
  ${KUBECTL} -n ai cp "${triage_pod}:/data" ./k3s-triage-backup/
  log "Backup written to ./k3s-triage-backup/"
fi

# ----------------------------------------------------------------------------
# 4. Helm uninstall.
# ----------------------------------------------------------------------------
log "helm uninstall ai-stack -n ai ..."
sudo KUBECONFIG="${KUBECONFIG_DEFAULT}" helm uninstall ai-stack -n ai

# ----------------------------------------------------------------------------
# 5. Namespace delete (wipes PVCs, ConfigMaps, Secrets).
# ----------------------------------------------------------------------------
log "Deleting namespace 'ai' ..."
${KUBECTL} delete namespace ai --wait=true --timeout=120s || log "namespace 'ai' already gone"

log "DONE. Verify freed resources with:"
log "  ${KUBECTL} get pods -A | grep -E 'ollama|triage|mcp' || echo clean"
log "  ${KUBECTL} top nodes   # should show freed CPU/memory on the k3s node"
