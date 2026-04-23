# Laptop integration test — Windows 11 + WSL2 walkthrough

Target: run the AI stack (Ollama + triage + 5 MCPs) on your MSI laptop
with the GTX 1060, using `qwen2.5:7b-instruct` to validate the pipeline
end-to-end before the cloud A10 arrives.

Estimated time: ~45 min first run, ~2 min to restart on subsequent days.

---

## Phase A — Laptop prep (~20 min, one-time)

### A1. Confirm Windows + driver versions

Open **PowerShell (admin)**:

```powershell
winver        # must be Windows 11 (22H2 or later)
wsl --version # must show WSL version 2.x, kernel 5.15 or later

# NVIDIA driver
nvidia-smi
# Expect output with Driver Version and "GeForce GTX 1060".
# Version should be >= 525.xx for clean WSL2 CUDA support. If older,
# update from https://www.nvidia.com/Download/index.aspx (select GTX 1060).
```

If `wsl --version` says WSL1 or errors: run `wsl --install` in PowerShell
(admin), reboot, then continue.

### A2. Install Ubuntu 22.04 under WSL2 (if not already present)

```powershell
wsl --list --verbose
```

- If a distro already shows up with `VERSION 2` and NAME `Ubuntu-22.04`,
  skip to A3.
- Otherwise:
  ```powershell
  wsl --install -d Ubuntu-22.04
  ```
  It will prompt you to create a UNIX username + password on first boot.
  Write them down — you'll use `sudo` inside WSL2 a lot.

### A3. Confirm GPU passthrough into WSL2

Still in PowerShell (or inside the Ubuntu shell):

```bash
wsl -d Ubuntu-22.04 -- nvidia-smi
```

If you see the 1060 listed with driver/CUDA version, **GPU passthrough
works**. Done. Otherwise:

- Update the Windows NVIDIA driver (A1 instructions).
- Reboot.
- Retry.

### A4. Configure Docker Desktop for WSL2 + GPU

Open **Docker Desktop → Settings**:

1. **General** → check *Use the WSL 2 based engine*. (Default on Win11.)
2. **Resources → WSL Integration** → toggle *Enable integration with my default WSL distro* **on**, AND explicitly toggle on `Ubuntu-22.04`.
3. **Resources** → leave Memory/CPU at defaults (Docker Desktop can use up to ~50% of system memory, which is plenty).
4. Apply & Restart Docker Desktop.

### A5. Verify Docker can reach the GPU

Open the **Ubuntu-22.04** terminal (Start menu → "Ubuntu 22.04"). From there:

```bash
# Quick smoke test — this pulls ~300 MB, one-time
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
```

Expected: same nvidia-smi output you saw in A3, but inside a container.
If it says `could not select device driver "" with capabilities: [[gpu]]`,
Docker Desktop didn't pick up the WSL GPU integration — restart Docker
Desktop and re-check A4.

### A6. Install Tailscale on Windows

Download installer from https://tailscale.com/download/windows.
Run, accept defaults, sign in with a Google/Microsoft/GitHub account
(use the same one you'll use on the monitoring VM in Phase B).

After install, right-click the Tailscale tray icon → your laptop should
appear in the "This machine" section with a `100.x.x.x` address. Note it
down — Grafana on the monitoring VM will POST webhooks to this IP.

**Optional but recommended:** enable *MagicDNS* in the Tailscale admin
console (https://login.tailscale.com/admin/dns) so you can reach peers
by name (`monitoring-vm.ts.net`) instead of raw IPs.

---

## Phase B — AWS re-up (~5 min)

We need the monitoring VM running so the MCPs have real Prometheus /
Loki / Jaeger to query. K3s stays stopped — it's only there for the
demo app, which you don't need for integration testing.

From the machine that runs `aws` CLI (your controller with creds):

```bash
# Start ONLY the monitoring VM (keep k3s stopped)
aws ec2 start-instances --region us-east-1 \
  --instance-ids i-012ab72d94c0437c7

# Wait ~90s for status checks to pass
aws ec2 wait instance-status-ok --region us-east-1 \
  --instance-ids i-012ab72d94c0437c7
```

EIP `52.202.21.192` auto-reattaches. Prometheus / Loki / Jaeger /
Grafana restart automatically via systemd.

### B1. Install Tailscale on the monitoring VM

```bash
ssh -i ~/.ssh/ansible_key deploy@52.202.21.192
```

On the monitoring VM:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --accept-routes
# This prints a login URL. Open it in your browser and sign in with the
# SAME account you used on the laptop.
```

Verify from the laptop (Ubuntu-22.04 shell):

```bash
tailscale status | grep monitoring
# Expect a line like:
#   100.X.Y.Z   observability-rca-monitoring   your-account@   linux   -
```

**Write down the monitoring VM's Tailscale IP** — you'll paste it into
`.env` in Phase C.

Quick reachability test:

```bash
# From the laptop Ubuntu shell:
curl -sSf http://<monitoring-tailscale-ip>:9090/-/ready && echo "Prometheus OK"
curl -sSf http://<monitoring-tailscale-ip>:3100/ready    && echo "Loki OK"
curl -sSf http://<monitoring-tailscale-ip>:16686/api/services && echo "Jaeger OK"
```

All three should return 200s. If any times out, restart Tailscale on the
monitoring VM: `sudo systemctl restart tailscaled`.

---

## Phase C — Bring up the AI stack on the laptop (~20 min)

### C1. Clone source repos INTO the WSL2 ext4 filesystem

Critical: clone into `~/cires-ai/`, NOT a Windows path like
`/mnt/c/Users/.../cires-ai/`. Docker build performance over the 9P bridge
to NTFS is ~10× slower than native ext4.

From the **Ubuntu-22.04** shell:

```bash
mkdir -p ~/cires-ai && cd ~/cires-ai

# Source for Docker build contexts
git clone https://github.com/linalaaraich/monitoring-triage-service.git
git clone https://github.com/linalaaraich/monitoring-mcp-servers.git
```

### C2. Copy the staged compose + env files

From the same Ubuntu shell, grab from wherever the staging folder lives
(adjust the SCP source to the machine with `/root/gpu-migration-staging/`):

```bash
# Replace <controller> with the machine holding the staging folder.
# If you've been running `aws` from this same laptop, the files are
# presumably local to the controller.
scp <controller>:/root/gpu-migration-staging/compose/docker-compose.yml ~/cires-ai/
scp <controller>:/root/gpu-migration-staging/laptop/.env.laptop ~/cires-ai/.env
scp <controller>:/root/monitoring-triage-service/drain3.ini ~/cires-ai/
scp <controller>:/root/gpu-migration-staging/laptop/sample-alert.json ~/cires-ai/
scp <controller>:/root/gpu-migration-staging/laptop/test-alert.sh ~/cires-ai/
chmod +x ~/cires-ai/test-alert.sh
```

### C3. Fill in `.env`

```bash
cd ~/cires-ai
nano .env
```

Replace:
- `MONITORING_VM_IP=REPLACE_WITH_MONITORING_TAILSCALE_IP` → the 100.x.x.x
  address you noted in B1.
- SMTP fields → reuse the Gmail creds from
  `/root/monitoring-project/inventory/group_vars/monitoring.yml`
  (look for `smtp_*` keys). If you want to skip email for the smoke
  test, leave the dummy REPLACE_ME values — email send will fail with
  a log line but the pipeline still produces a verdict.

### C4. Build the 6 custom images

```bash
cd ~/cires-ai

# Triage
docker build -t cires/triage-service:laptop-dev \
  -f monitoring-triage-service/Dockerfile \
  monitoring-triage-service/

# 5 MCPs (each from its subfolder, with the shared repo root as context)
for mcp in prometheus loki jaeger drain3 rca_history; do
  docker build -t cires/mcp-${mcp/_/-}:laptop-dev \
    -f monitoring-mcp-servers/${mcp}_mcp/Dockerfile \
    monitoring-mcp-servers/
done
```

The builds take ~3–5 min total (most of it Python wheel installs). Run
them serially so a laptop on battery doesn't thermal-throttle.

### C5. Bring up the stack

```bash
docker compose up -d
```

This will:

1. Pull `ollama/ollama:0.5.7` (~600 MB one-time).
2. Start `ollama`, then wait for it to pass healthcheck.
3. Start `ollama-init`, which runs `ollama pull qwen2.5:7b` (~5 GB,
   one-time, 5–10 min on a decent connection). The main `ollama` service
   and the other services stay up during this; triage and rca-history-mcp
   both depend on `ollama-init` completing successfully before starting.
4. Start triage-service, the 3 stateless MCPs, then drain3-mcp and
   rca-history-mcp (those two wait for triage to be healthy).

Watch progress:

```bash
docker compose logs -f --tail=20 ollama-init     # model pull
docker compose ps                                # service status column
```

Wait until:
- `ollama-init` shows `Exited (0)` ← model is pulled
- `triage-service` shows `healthy`
- All 5 MCPs show `healthy` (or `unhealthy` — see troubleshooting below)

---

## Phase D — Integration test (~5 min)

### D1. Smoke test the triage service itself

```bash
curl -sSf http://localhost:8090/health | python3 -m json.tool
# Expect: {"uptime_seconds": N, ...}
```

### D2. Fire a synthetic alert and wait for a verdict

```bash
./test-alert.sh
```

This script:
- POSTs a realistic `BackendHigh5xxRate` alert payload to the webhook.
- Polls `/decisions` every 10s for up to 15 min.
- Prints the verdict JSON when it lands.

Expected timing on GTX 1060 + qwen2.5:7b:

- Context gather (MCPs fan-out): 1–3 s
- LLM inference (verdict): 60–120 s
- Total time-to-verdict: **~2 min** (vs. 20–40 min on k3s CPU — you'll feel the difference)

### D3. Open the dashboard

Open `http://localhost:8090/dashboard` in your Windows browser. The
alert you just fired should be at the top with its verdict, reasoning,
and evidence sections populated.

### D4. (Optional) Wire up Grafana to point at the laptop

If you want to test the full Grafana → triage webhook path (rather than
just a curl POST), edit the monitoring VM's Grafana contact point:

```bash
ssh -i ~/.ssh/ansible_key deploy@52.202.21.192
# Edit /etc/grafana/provisioning/alerting/contactpoints.yml or the
# equivalent Ansible-templated file; point url: to
# http://<laptop-tailscale-ip>:8090/webhook/grafana
sudo systemctl restart grafana-server
```

Then in Grafana UI: Alerting → Contact points → "Test" the
`triage-service-webhook` point. A decision should land in your laptop's
`/dashboard` within ~2 min.

---

## Cleanup when done

```bash
# On the laptop (Ubuntu shell)
docker compose down
# Leaves named volumes (ollama_data, triage_data) intact so next run
# skips the 5 GB model re-pull.
```

```bash
# Stop the monitoring VM again
aws ec2 stop-instances --region us-east-1 --instance-ids i-012ab72d94c0437c7
```

Tailscale stays configured on both ends — zero ongoing cost, and next
time you restart the monitoring VM it auto-rejoins the tailnet.

---

## Troubleshooting

### "MCP shows unhealthy in docker compose ps"

Each MCP's `/health` probes its upstream (prometheus-mcp hits
`{PROMETHEUS_URL}/-/ready`, etc.). If the monitoring VM is reachable
on Tailscale, these should all be healthy. If one is stuck unhealthy:

```bash
docker compose logs --tail=50 <service-name>
# Look for httpx timeouts or ConnectionError tracebacks.
```

Common causes:
- Monitoring VM not actually in the tailnet — re-run `tailscale up` on it.
- Wrong `MONITORING_VM_IP` in `.env` — compare to `tailscale status`.
- Firewall inside the monitoring VM's Tailscale interface — should be
  open by default; verify with `sudo ss -lntp | grep -E '9090|3100|16686'`
  on the monitoring VM.

### "Ollama log says 'cudaMalloc failed' or falls back to CPU"

6 GB VRAM is tight. Close other GPU-heavy apps on Windows (Chrome with
many tabs, Electron apps like VS Code, games).

Check VRAM usage:

```bash
# Inside the ollama container
docker exec ai-ollama nvidia-smi
```

If the 1060 is holding ~5+ GB for other processes, qwen2.5:7b won't fit.
You may need to close those apps, or accept CPU fallback (Ollama will
happily run on CPU — just slower).

### "Triage verdict is generic / 'insufficient evidence'"

That's expected for a synthetic alert against real monitoring data the
LLM has no context for. The point of the smoke test is to validate the
pipeline, not the quality of the verdict. For realistic verdicts, you'd
need to also have the `react-springboot-mysql` app emitting real errors
— which requires the k3s VM running. Out of scope for this phase.

### "test-alert.sh times out at 15 min"

Check triage logs:

```bash
docker compose logs --tail=100 triage-service | grep -E 'ERROR|WARNING|timeout'
```

Most likely causes:
- Ollama is CPU-bound (see above) — inference took > 15 min.
- An MCP is returning 500s and triage's circuit breaker opened — verify
  `docker compose ps` shows all MCPs healthy.
- qwen2.5:7b is still pulling — check `docker compose logs ollama-init`.
