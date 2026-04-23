# CIRES AI stack — GPU migration staging

> **⚠️ Nothing in this repo has been deployed.** Every file here is a
> dry-run draft staged on 2026-04-23 for review before anything runs
> against AWS or any laptop. No `terraform apply`, no `ansible-playbook`,
> no `docker compose up` has happened from this directory.

This repo captures the code side of the architectural pivot documented
in [`monitoring-docs/sprint3-backlog.md`](https://github.com/linalaaraich/monitoring-docs/blob/main/sprint3-backlog.md#4-ai-placement-migration--off-k3s-onto-a-dedicated-gpu-instance) §4 and §5: move the AI stack
(Ollama + triage + 5 MCP servers) off the k3s cluster onto a dedicated
GPU instance, running `qwen2.5:14b-instruct` on an A10/A10G-class GPU.

## Start here

| If you want to… | Read this |
|---|---|
| Run the stack on your laptop (GTX 1060, integration test, 7B model) | **[laptop/WINDOWS_11_WALKTHROUGH.md](laptop/WINDOWS_11_WALKTHROUGH.md)** |
| See the overall migration plan, phasing, rollback, foolproofing | [PLAN.md](PLAN.md) |
| Apply the Terraform once the AWS quota clears | [terraform/NOTES.md](terraform/NOTES.md) |
| Understand the runtime (docker-compose on the GPU box) | [compose/docker-compose.yml](compose/docker-compose.yml) |
| See how Ansible wires it together | [ansible/playbooks/gpu.yml](ansible/playbooks/gpu.yml) |

## Repo layout

```
.
├── PLAN.md                                   ← master plan, 6 phases
├── README.md                                 ← this file
│
├── terraform/                                ← Phase 1 + 6 infra
│   ├── NOTES.md
│   ├── variables.tf.addition
│   ├── ec2.tf.patch
│   ├── security-groups.tf.addition
│   └── terraform.tfvars.new
│
├── compose/                                  ← Phase 2 runtime (AUTHORITATIVE)
│   ├── docker-compose.yml
│   └── .env.example
│
├── ansible/                                  ← Phase 2 automation
│   ├── playbooks/gpu.yml
│   └── roles/gpu_stack/
│       ├── defaults/main.yml
│       ├── tasks/main.yml
│       ├── handlers/main.yml
│       └── templates/{docker-compose.yml.j2, env.j2}
│
├── grafana/
│   └── contactpoints.yml.j2.patch            ← Phase 3 webhook repoint
│
├── k3s-teardown/
│   └── uninstall-ai-stack.sh                 ← Phase 4 helm uninstall (4-check preflight)
│
├── scripts/
│   └── benchmark.sh                          ← Phase 0 + 5 baseline-vs-GPU
│
└── laptop/                                   ← Interim path — no cloud GPU required
    ├── WINDOWS_11_WALKTHROUGH.md
    ├── .env.laptop
    ├── sample-alert.json
    └── test-alert.sh
```

## Related repos

- [`monitoring-triage-service`](https://github.com/linalaaraich/monitoring-triage-service) — FastAPI triage orchestrator
- [`monitoring-mcp-servers`](https://github.com/linalaaraich/monitoring-mcp-servers) — 5 MCP bridges (Prometheus, Loki, Jaeger, Drain3, RCA history)
- [`monitoring-project`](https://github.com/linalaaraich/monitoring-project) — Ansible + Helm charts
- [`provisioning-monitoring-infra`](https://github.com/linalaaraich/provisioning-monitoring-infra) — Terraform for AWS
- [`monitoring-docs`](https://github.com/linalaaraich/monitoring-docs) — architecture + backlog docs (GitHub Pages)

## Status (2026-04-23)

- AWS `us-east-1` G-family quota request (`5eb7f81a4c...`): escalated to capacity team, no ETA.
- AWS `us-west-2` parallel quota request: 24h review window.
- Monitoring VM + k3s VM stopped pending quota approval (save cost).
- Laptop integration path (Phase A–D in [WINDOWS_11_WALKTHROUGH.md](laptop/WINDOWS_11_WALKTHROUGH.md)) is the bridging option while the quota clears.
