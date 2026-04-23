# GPU Migration — Staged Plan (2026-04-23)

> **Nothing in this folder has been applied to any live system.** Every
> file here is a dry-run draft that must be read by a human eye and
> merged into the real repos before it runs. Nothing has been `git
> pushed`, no `terraform apply` has executed, no Ansible playbook has
> been invoked. This is the code side of the migration described in
> `monitoring-docs/sprint3-backlog.md §4`.

## What this migration does

Move the AI stack (Ollama + triage-service + 5 MCP servers) **out of
the k3s cluster** onto a **dedicated g5.xlarge GPU EC2 instance** running
docker-compose, with model = `qwen2.5:14b-instruct-q4_K_M`. Downsize
the k3s VM once the AI has moved. All infrastructure already has
security groups, VPC subnets, and `enable_gpu` scaffolding in Terraform
— this migration flips the switch, not rebuilds the stack.

## Preconditions (must be true before any step runs)

- [ ] **Quota APPROVED.** `aws service-quotas get-service-quota
      --service-code ec2 --quota-code L-DB2E81BA --region us-east-1`
      returns `Value >= 4` (or `>= 8` for headroom to upsize). If `us-west-2`
      wins the quota race first, swap region here and in the Terraform
      `aws_region` var.
- [ ] **DLAMI AMI ID pinned.** `terraform.tfvars.new` has a real
      `gpu_ami_id = "ami-..."` instead of the placeholder. Find with
      the command in `terraform/NOTES.md`.
- [ ] **All 6 repos at clean HEAD on `main`.**
      `git -C /root/<repo> status` → `nothing to commit, working tree clean`
      for each of monitoring-project, monitoring-triage-service,
      monitoring-mcp-servers, provisioning-monitoring-infra, monitoring-docs,
      react-springboot-mysql.
- [ ] **SMTP creds in ansible vault** at
      `/root/monitoring-project/inventory/group_vars/ai/vault.yml`
      (encrypted). Reuse the existing monitoring vault password.
- [ ] **Baseline benchmark done** before uninstalling the k3s AI —
      run `scripts/benchmark.sh` against the CURRENT k3s triage first
      so we have an apples-to-apples before/after comparison.

## Ordered sequence of operations

```
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 0 — benchmark baseline (do BEFORE any change)                   │
│   TARGET=http://52.5.239.234:30080 PATH_PREFIX=/triage N=10 \         │
│     ./scripts/benchmark.sh                                            │
│   → saves CSV baseline. Compare against GPU run at the end.           │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 1 — Terraform (create GPU only; k3s untouched)                  │
│   1. Splice staged tf files into provisioning-monitoring-infra/       │
│   2. terraform plan -out=plan.out                                     │
│   3. Visually scan for unexpected changes (see terraform/NOTES.md)    │
│   4. terraform apply plan.out                                         │
│   5. Capture gpu_eip and gpu_private_ip                               │
│      — add gpu-vm to monitoring-project inventory/production.yml      │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 2 — Ansible (bootstrap AI stack on the GPU box)                 │
│   1. Copy gpu.yml → /root/monitoring-project/playbooks/gpu.yml        │
│   2. Copy role → /root/monitoring-project/roles/ai_stack_compose/     │
│   3. Create group_vars/ai.yml (non-secret) and group_vars/ai/vault.yml│
│      (SMTP creds, ansible-vault encrypted).                           │
│   4. ansible-playbook playbooks/gpu.yml --ask-vault-pass              │
│      — rsyncs sources, builds 6 images, pulls qwen2.5:14b, compose up │
│      — post_tasks block in the playbook auto-asserts /health for      │
│        triage + ollama + all 5 MCPs before succeeding.                │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 3 — switchover (route traffic to the GPU box)                   │
│   1. Apply grafana/contactpoints.yml.j2.patch                         │
│      + add ai_gpu_vm_ip var to group_vars/monitoring.yml              │
│   2. ansible-playbook playbooks/monitoring.yml --tags grafana         │
│   3. Verify in Grafana UI → Alerting → Contact points:                │
│      URL is now http://<gpu-eip>:8090/webhook/grafana                 │
│   4. Fire a Grafana "Test" on the contact point; curl                 │
│      http://<gpu-eip>:8090/decisions?limit=5 to confirm decision lands│
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 4 — tear down k3s AI                                            │
│   GPU_EIP=<gpu-eip> k3s-teardown/uninstall-ai-stack.sh                │
│   (Does 4 safety checks + helm uninstall + namespace delete.)         │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 5 — GPU benchmark (compare to Phase 0 baseline)                 │
│   TARGET=http://<gpu-eip>:8090 N=10 ./scripts/benchmark.sh            │
│   → diff the two CSVs; write up results per §4 pass/fail criteria.    │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ PHASE 6 (OPTIONAL) — downsize k3s                                     │
│   Edit terraform.tfvars: k3s_instance_type = "t3.large"               │
│   terraform plan -out=plan.out && terraform apply plan.out            │
│   (~2 min of k3s downtime; EBS + EIP preserved.)                      │
└───────────────────────────────────────────────────────────────────────┘
```

## File manifest

```
/root/gpu-migration-staging/
├── PLAN.md                                        ← you are here
│
├── terraform/
│   ├── NOTES.md                                   ← step-by-step apply + rollback
│   ├── variables.tf.addition                      ← add gpu_ami_id var
│   ├── ec2.tf.patch                               ← replaces aws_instance.gpu block
│   ├── security-groups.tf.addition                ← opens 8090 dashboard to operators
│   └── terraform.tfvars.new                       ← full replacement tfvars
│
├── compose/
│   ├── docker-compose.yml                         ← AUTHORITATIVE runtime spec
│   ├── .env.example                               ← env vars + secrets template
│   └── (drain3.ini is rsync'd from monitoring-triage-service source)
│
├── ansible/
│   ├── playbooks/
│   │   └── gpu.yml                                ← top-level playbook w/ post-task asserts
│   └── roles/gpu_stack/
│       ├── defaults/main.yml                      ← variables + image registry
│       ├── tasks/main.yml                         ← rsync → render → build → up
│       ├── handlers/main.yml                      ← rebuild + recreate handlers
│       └── templates/
│           ├── docker-compose.yml.j2              ← copy of compose/ + managed-by header
│           └── env.j2                             ← .env render from vault
│
├── grafana/
│   └── contactpoints.yml.j2.patch                 ← webhook URL repoint instructions
│
├── k3s-teardown/
│   └── uninstall-ai-stack.sh                      ← 4-safety-check helm uninstall
│
└── scripts/
    └── benchmark.sh                               ← baseline + GPU bench harness
```

## Design decisions (why things are the way they are)

### Why docker-compose and not k3s-on-the-GPU-box
One node, one workload, one-day validation window. K3s adds:
- etcd + kine + node-agent + scheduler — ~400 MB RAM overhead per node.
- Helm release lifecycle ceremony — an extra indirection layer above the
  only thing that matters (the containers).
- PVC/StorageClass wrangling — trivial in compose with a named volume.

Nothing in the runtime contract needs k3s-specific features. Compose is
simpler, the image builds run on the same box, and the whole project
fits in one `docker-compose.yml`.

### Why keep the code paths identical between k3s and compose
The triage + MCP env-var names, ports, and URL shapes are EXACTLY the
same on both stacks. If §5 of `sprint3-backlog.md` (the MCP tool-calling
rewrite) happens after the GPU migration, no compose-specific code
survives to clean up. The triage service can't tell whether it's under
k3s or compose.

### Why a separate `ollama-init` one-shot service
Ollama's `postStart` lifecycle hook (how the k3s chart pulled the model)
doesn't exist in compose. The alternatives:
- Bake the model into a custom Ollama image: ~9 GB image, slow to
  push/pull, tight coupling to the chosen model, painful to A/B.
- Put `ollama pull` in the triage startup: model pull blocks triage
  readiness; crash-looping Ollama would crash-loop triage too.
- **One-shot sidecar + `depends_on: service_completed_successfully`
  (chosen).** Clean separation; `ollama pull` is idempotent so re-running
  is a ~1s no-op on subsequent boots.

### Why the bundled `triage_data` volume
Three containers read/write `/data`: triage (RW — DB + drain3 state),
rca-history-mcp (RW for SQLite open), drain3-mcp (reads state for stats).
A single named volume matches the k3s chart's shared PVC semantics
exactly. Zero code changes required.

### Why `restart: unless-stopped`, not `restart: always`
`always` restarts after a manual `docker compose stop` — which is bad
ops hygiene when you want to pause the stack for debugging. `unless-stopped`
gives us auto-recovery from crashes while still respecting operator
intent.

### Why the in-place k3s downsize (Phase 6) runs LAST
Stopping the k3s instance for 2 minutes disrupts the Spring Boot app,
Kong, and the OTel collector on that node. We intentionally defer until
all AI workloads are off k3s so the only visible impact is a brief app
gap, and we've already moved the "important" piece (AI) to its own box
that's not affected by the k3s restart.

### Why the benchmark is the LAST step, not a middle one
Running benchmark.sh against the GPU box before Phase 3 means firing
against a stack where Grafana ISN'T yet routing alerts there — you'd
test the `/webhook/grafana` path but not the real Grafana-initiated
flow, which exercises Alertmanager contact point resolution, SG traffic
from the monitoring VM, and the Drain3 background ingestion loop. Save
it for after the switchover so the benchmark measures the real system.

## Foolproofing checklist (what each layer enforces so we don't re-patch)

| Layer | Mechanism | Catches |
|---|---|---|
| Terraform validation | `gpu_ami_id` regex validation | Forgetting to replace the AMI placeholder. |
| Terraform plan | No `local.user_data` change → no forced recreation of monitoring / k3s | User-data drift accidentally rebuilding existing VMs. |
| Terraform `lifecycle { ignore_changes = [user_data] }` on GPU | Subsequent tfvars tweaks don't force a GPU rebuild | Accidentally destroying the box by editing user-data. |
| Ansible `pre_tasks` | Assert `monitoring_vm_ip`, `triage_smtp_user`, `image_tag`, etc. are set | Running the role with a half-configured vault. |
| Ansible `pre_tasks` | `nvidia-smi`, `docker --version`, `nvidia-ctk --version` must succeed | Wrong AMI (non-DLAMI) — catch before wasting the `docker pull`. |
| Compose `${VAR:?}` interpolation | `docker compose up` fails loud if a required env is missing | Silent misconfig of the SMTP creds or IMAGE_TAG. |
| Compose healthchecks on every service | `docker ps` shows `unhealthy` instead of "running but broken" | Silent-fail services (e.g., MCP can't reach monitoring). |
| Compose `depends_on: service_completed_successfully` on `ollama-init` | Triage never starts until the model is verifiably pulled | Race condition where first alert 404s because the model isn't loaded. |
| Ansible `post_tasks` | Poll `/health` on all 7 services post-apply with `retries: 30`, `delay: 10` | Playbook "succeeds" but stack isn't actually healthy. |
| Teardown script 4-check pre-flight | Verify GPU /health AND helm release exists BEFORE uninstalling k3s AI | Accidentally tearing down the only working AI instance. |
| Benchmark script | TIMEOUT column in CSV + POST_FAIL row | Silent black-hole after a webhook repoint. |

## Things NOT done by this staging (parking lot)

- **`us-west-2` Terraform variant.** If `us-west-2` wins the quota race,
  we need to pin a `us-west-2` DLAMI, flip `aws_region`, and add an
  inbound rule on `sg-monitoring` allowing the new GPU EIP to reach
  Prometheus/Loki/Jaeger over public routing. Estimated 20 min of
  additional work; not staged until Lina confirms we're filing in
  `us-west-2`.
- **`outputs.tf` update** to surface `gpu_eip` / `gpu_private_ip` as
  terraform outputs. Mentioned in `terraform/NOTES.md` as an optional
  nice-to-have.
- **Grafana dashboard for the GPU instance** (GPU utilization, inference
  tokens/sec, VRAM used). Can be a follow-up once we see the benchmark
  numbers and know what's worth charting.
- **Tool-calling rewrite (`sprint3-backlog.md §5`)**. That's a triage-
  service code change, not an infra change — out of scope for this
  migration. Lands after the benchmark confirms GPU inference is
  tractable.
- **Ansible-vault wiring of SMTP creds**. This staging documents the
  file path but doesn't populate it — user-driven secret handling.
