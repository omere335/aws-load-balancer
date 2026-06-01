# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

Provision a Docker-based cluster on an AWS EC2 instance using Terraform. The cluster consists of multiple nginx web server containers behind a round-robin nginx load balancer, each accessible via a `/health` endpoint.

## Bootstrap (one-time, before first use)

The S3 bucket used for remote state must exist before running `terraform init` in the root. Provision it once from the `bootstrap/` directory:

```bash
cd bootstrap
terraform init
terraform apply
cd ..
```

If you already have local state to migrate, run `terraform init -migrate-state` instead of plain `terraform init` in the root after bootstrapping.

## Common Commands

```bash
# Initialize Terraform and download providers/plugins
terraform init

# Validate configuration syntax
terraform validate

# Preview changes (prompts for public_key and ssh_allowed_cidr)
terraform plan

# Apply infrastructure
terraform apply

# Destroy infrastructure
terraform destroy

# Lint
tflint --init
tflint --recursive

# Security scan
trivy config .

# Pre-commit setup (runs terraform_fmt on commit, trivy on push)
pre-commit install
pre-commit run --all-files
```

## Variables

Two variables have no defaults and must be supplied at plan/apply time:
- `public_key` — SSH public key material (contents of `.pub` file) used to create the EC2 key pair
- `ssh_allowed_cidr` — your IP in CIDR notation (e.g. `1.2.3.4/32`)

Variables with defaults:
- `aws_region` — defaults to `il-central-1`
- `instance_type` — defaults to `t3.micro`
- `web_server_count` — defaults to `2`
- `vpc_id` — defaults to a hardcoded VPC ID specific to `il-central-1`; override if deploying to a different region

`terraform.tfvars` is committed with `public_key` and `ssh_allowed_cidr` already set for local use, so plain `terraform plan` / `terraform apply` works without extra `-var` flags.

## Architecture

**Providers & versions** — `terraform.tf` pins Terraform `>= 1.10` and AWS provider `~> 6.37`. Remote state is stored in S3 (`aws-load-balancer-terraform-state`) with S3 native locking (`use_lockfile = true`), in `il-central-1`.

**EC2 instance** — `main.tf` uses the `terraform-aws-modules/ec2-instance/aws` module (v6.4.0). The AMI is resolved via a `data.aws_ami` filter for the latest Amazon Linux 2023 (`al2023-ami-*-x86_64`). The subnet is resolved dynamically via `data.aws_subnets` filtering by `var.vpc_id` for subnets with `map-public-ip-on-launch = true`. The key pair (`aws_key_pair.this`) is managed by Terraform from `var.public_key` — no pre-existing key pair needed.

**User data** — `user_data.sh` is rendered via `templatefile()` with the `web_server_count` variable injected. At boot it installs Docker, starts `web_server_count` nginx containers on ports `8001..800N` (BASE_PORT=8000, ports are BASE_PORT+i), then generates an nginx upstream config and starts a load balancer container in host-network mode on port 80. Shell variables inside `user_data.sh` use single `$` (e.g. `$PORT`) — Terraform only interpolates `${...}` sequences so bare shell variables are safe. Only the Terraform template variable uses braces: `${web_server_count}`. `user_data_replace_on_change = true` is set, so any change to `user_data.sh` or `web_server_count` automatically triggers instance replacement on the next apply.

**Security group** — separate `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` resources (not inline rules) for HTTP (80), HTTPS (443), SSH (22 from `ssh_allowed_cidr`), and all egress.

## Tooling

- **tflint** — AWS ruleset plugin (`0.47.0`), config in `.tflint.hcl`
- **trivy** — security scanner; runs as a `pre-push` hook (not pre-commit) via `antonbabenko/pre-commit-terraform`; skips `.terraform/` dirs
- **terraform_fmt** — runs as a `pre-commit` hook
- **GitHub Actions** — tflint runs on every push/PR (failures block PRs but are allowed on push); `terraform plan` runs on every PR and posts output as a PR comment; `terraform apply` runs automatically on every push to `main`

## Trivy Suppressions

`.trivyignore` suppresses two findings intentionally:
- `AVD-AWS-0107` — HTTP/HTTPS open to internet (expected for a public-facing load balancer)
- `AVD-AWS-0104` — unrestricted egress (required so the instance can pull Docker images at boot)

## GitHub Actions Secrets & Variables

CI authenticates to AWS using these repository secrets/vars (configured under Settings → Environments → production):
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — IAM credentials
- `AWS_REGION` (var, not secret) — e.g. `il-central-1`
- `TF_VAR_PUBLIC_KEY` — SSH public key material, passed as `-var="public_key=..."`
- `TF_VAR_SSH_ALLOWED_CIDR` — passed as `-var="ssh_allowed_cidr=..."`
