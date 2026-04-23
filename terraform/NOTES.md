# Terraform staging — apply instructions

> **Nothing here has been applied.** These files describe the desired
> end-state and the steps to reach it. Read the whole doc before
> running any command.

## Files in this directory

| File | Kind | Applies to |
|---|---|---|
| `variables.tf.addition` | append-only snippet | `/root/provisioning-monitoring-infra/variables.tf` |
| `ec2.tf.patch` | replacement for the `aws_instance "gpu"` + EIP-association blocks | `/root/provisioning-monitoring-infra/ec2.tf` |
| `security-groups.tf.addition` | append-only snippet (one new ingress rule) | `/root/provisioning-monitoring-infra/security-groups.tf` |
| `terraform.tfvars.new` | full replacement | `/root/provisioning-monitoring-infra/terraform.tfvars` |

## Pre-flight

1. **Quota must be APPROVED first** (request `5eb7f81a4c3346d9bbba4e90cf41b72cOQHLSxux` in `us-east-1`, or whichever region wins). `terraform apply` with `enable_gpu=true` before quota lands will fail at `RunInstances` with `VcpuLimitExceeded`, leaving state inconsistent.

2. **Find the current Deep Learning Base AMI OSS Nvidia Driver ID** and paste it into `terraform.tfvars.new`:

   ```bash
   aws ec2 describe-images \
     --owners amazon \
     --filters "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
     --query 'sort_by(Images, &CreationDate)[-1].[ImageId,Name,CreationDate]' \
     --region us-east-1 \
     --output text
   ```

   Copy the `ami-...` into the `gpu_ami_id = "..."` line. If you leave the placeholder, `terraform plan` fails the regex validation on purpose — that's the guard that catches "forgot to pick an AMI."

3. **Confirm nothing else has drifted** since the last apply:

   ```bash
   cd /root/provisioning-monitoring-infra
   terraform plan
   ```

   You should see only the intended changes (GPU instance + EIP + SG rule create; k3s instance_type in-place modify if you've gone to Phase 2). Anything else is suspicious.

## Apply procedure (Phase 1: add the GPU box only)

This phase creates the GPU instance and its networking but leaves k3s at
`t3.xlarge` so the AI stack there stays online as a fallback while the
new box comes up.

1. **Splice the staged files into the real repo:**

   ```bash
   cd /root/provisioning-monitoring-infra

   # append the new variable
   cat /root/gpu-migration-staging/terraform/variables.tf.addition >> variables.tf

   # replace the aws_instance "gpu" + aws_eip_association "gpu" blocks in ec2.tf
   # (manual edit — these are scoped blocks at the bottom of the file; use your editor)
   # OR: patch in-place, see "patch method" below

   # append the new SG rule
   cat /root/gpu-migration-staging/terraform/security-groups.tf.addition >> security-groups.tf

   # replace the tfvars
   cp /root/gpu-migration-staging/terraform/terraform.tfvars.new terraform.tfvars
   ```

2. **Plan → scan the output with a fresh set of eyes:**

   ```bash
   terraform plan -out=plan.out | tee plan.txt
   ```

   Expected changes in `plan.out`:
   - `+ aws_eip.gpu[0]` (create)
   - `+ aws_instance.gpu[0]` (create)
   - `+ aws_eip_association.gpu[0]` (create)
   - `+ aws_vpc_security_group_ingress_rule.gpu_triage_dashboard["<cidr>"]` (create, one per allowed_ssh_cidrs entry)
   - **NO `~ aws_instance.k3s[0]`** in Phase 1. If you see one, `k3s_instance_type` was already changed to `t3.large` — revert to `t3.xlarge` until Phase 2.

   Watch for:
   - Any `-/+` destroy-then-create on monitoring or k3s. If either is marked for replacement, STOP and investigate — this plan should not touch existing instances.
   - User-data drift on existing instances (should be absent because `ec2.tf.patch` keeps `local.user_data` unchanged).

3. **Apply:**

   ```bash
   terraform apply plan.out
   ```

4. **Capture the GPU EIP:**

   ```bash
   terraform output -raw gpu_eip  # if you added an output
   # OR
   terraform show -json | jq -r '.values.root_module.resources[] | select(.address=="aws_eip.gpu[0]") | .values.public_ip'
   ```

   Paste it into `inventory/production.yml` under the `ai:` host group
   (see `ansible/playbooks/gpu.yml` header).

## Apply procedure (Phase 2: downsize k3s)

Only after:
- GPU box is healthy (`curl http://<gpu-eip>:8090/health` → 200).
- Helm release `ai-stack` is uninstalled from the k3s cluster.
- Grafana webhook is repointed to the GPU box and verified working.

Then:

1. Edit `terraform.tfvars`:
   ```hcl
   k3s_instance_type = "t3.large"   # was t3.xlarge
   ```

2. `terraform plan -out=plan.out` — expected change:
   - `~ aws_instance.k3s[0]` in-place modify (`instance_type: "t3.xlarge" -> "t3.large"`).
   - No replacement. EBS + EIP preserved.

3. `terraform apply plan.out` — AWS will stop, modify, and restart the
   instance. ~2 minutes of k3s downtime. The Spring Boot app + Kong are
   briefly unavailable; Grafana will log the brief scrape gap. Acceptable.

## Rollback

| After step | To roll back |
|---|---|
| Step 3 apply (GPU created) | `terraform destroy -target='aws_eip_association.gpu[0]' -target='aws_instance.gpu[0]' -target='aws_eip.gpu[0]' -target='aws_vpc_security_group_ingress_rule.gpu_triage_dashboard'` |
| Phase 2 apply (k3s downsized) | revert `k3s_instance_type` in tfvars, re-plan, re-apply (another ~2-min downtime) |

No change here is destructive to existing state (EBS, RDS, S3, VPC — none touched).

## Outputs to add (optional nice-to-have)

Append to `/root/provisioning-monitoring-infra/outputs.tf` for clean
Ansible wiring:

```hcl
output "gpu_eip" {
  description = "Public IP of the GPU VM (if provisioned)"
  value       = try(aws_eip.gpu[0].public_ip, null)
}

output "gpu_private_ip" {
  description = "Private IP of the GPU VM (if provisioned)"
  value       = try(aws_instance.gpu[0].private_ip, null)
}
```

Then `terraform output -raw gpu_eip` becomes the authoritative source
for the Ansible inventory update and the Grafana webhook URL.
