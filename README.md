# aws-load-balancer

Provision a Docker-based web cluster on a single AWS EC2 instance using Terraform. The instance boots a configurable number of nginx web server containers behind a round-robin nginx load balancer, each reachable through a `/health` endpoint.

## Architecture

```
                         Internet
                            │
                  HTTP :80 / HTTPS :443
                            │
        ┌───────────────────▼────────────────────┐
        │          EC2 instance (AL2023)         │
        │                                        │
        │   ┌─────────────────────────────────┐  │
        │   │  loadbalancer (nginx)           │  │
        │   │  host network, listens :80      │  │
        │   │  round-robin upstream           │  │
        │   └───────┬───────────────┬─────────┘  │
        │           │               │            │
        │    127.0.0.1:8001   127.0.0.1:800N     │
        │           │               │            │
        │   ┌───────▼─────┐   ┌─────▼───────┐    │
        │   │ webserver-1 │ … │ webserver-N │    │
        │   │  (nginx)    │   │  (nginx)    │    │
        │   │  /health    │   │  /health    │    │
        │   └─────────────┘   └─────────────┘    │
        └────────────────────────────────────────┘
```

- A single EC2 instance runs everything via Docker.
- `web_server_count` nginx containers each listen on host ports `8001..800N` (`BASE_PORT=8000`, port = `BASE_PORT + i`).
- A separate nginx container runs in **host-network mode** on port `80` and round-robins requests across the web servers using an `upstream` block.
- Every web server exposes `GET /health`, which returns `healthy - port <PORT>` so you can confirm which backend served the request.

## Repository layout

| Path | Purpose |
| --- | --- |
| `terraform.tf` | Terraform/provider version pins and S3 remote-state backend config |
| `main.tf` | Provider, AMI/subnet data sources, key pair, security group, EC2 instance module |
| `variables.tf` | Input variable definitions |
| `terraform.tfvars` | Committed values for `public_key` and `ssh_allowed_cidr` for local use |
| `user_data.sh` | Cloud-init script (rendered via `templatefile`) that installs Docker and starts the containers |
| `bootstrap/` | One-time provisioning of the S3 state bucket |
| `.github/workflows/` | CI: tflint, terraform plan (PR), terraform apply (push to `main`), Claude review |
| `.tflint.hcl` | tflint AWS ruleset config |
| `.trivyignore` | Intentionally suppressed trivy findings |
| `.pre-commit-config.yaml` | `terraform_fmt` (pre-commit) and `trivy` (pre-push) hooks |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.10`
- An AWS account with credentials configured (e.g. `aws configure` or environment variables)
- An SSH key pair — the **public** key material is passed into Terraform; keep the private key safe
- Optional tooling: [tflint](https://github.com/terraform-linters/tflint), [trivy](https://github.com/aquasecurity/trivy), [pre-commit](https://pre-commit.com/)

## Bootstrap (one-time)

The S3 bucket used for remote state must exist **before** the first `terraform init` in the root. The `bootstrap/` directory provisions a versioned, encrypted, public-access-blocked bucket (`aws-load-balancer-terraform-state`) with `prevent_destroy` enabled.

```bash
cd bootstrap
terraform init
terraform apply
cd ..
```

If you already have local state to migrate into S3, run `terraform init -migrate-state` in the root after bootstrapping instead of a plain `terraform init`.

## Usage

```bash
# Initialize Terraform and download providers/plugins
terraform init

# Validate configuration syntax
terraform validate

# Preview changes
terraform plan

# Apply infrastructure
terraform apply

# Tear everything down
terraform destroy
```

`terraform.tfvars` is committed with `public_key` and `ssh_allowed_cidr` already set, so plain `terraform plan` / `terraform apply` works without extra `-var` flags for local use.

Once applied, grab the instance's public IP from the AWS console (or `terraform state show`/the module outputs) and hit it:

```bash
curl http://<public-ip>/         # round-robins across the web servers
curl http://<public-ip>/health   # e.g. "healthy - port 8001"
```

Repeating the `/health` call shows the port cycling between backends, confirming the load balancer is distributing traffic.

## Variables

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `public_key` | **Yes** | — | SSH public key material (contents of your `.pub` file) used to create the EC2 key pair |
| `ssh_allowed_cidr` | **Yes** | — | CIDR block allowed to SSH into the instance (e.g. `1.2.3.4/32`) |
| `aws_region` | No | `il-central-1` | AWS region to deploy into |
| `instance_type` | No | `t3.micro` | EC2 instance type |
| `web_server_count` | No | `2` | Number of nginx web server containers to run |
| `vpc_id` | No | `vpc-0e6ecadab552e1740` | VPC to deploy into; override if deploying to a different region |

> The default `vpc_id` is specific to `il-central-1`. If you change `aws_region`, you must also supply a matching `vpc_id`.

## How it works

**Providers & state** — `terraform.tf` pins Terraform `>= 1.10` and the AWS provider `~> 6.37`. State is stored in S3 (`aws-load-balancer-terraform-state`, `il-central-1`) with encryption and S3 native locking (`use_lockfile = true`).

**AMI & subnet** — the AMI is resolved dynamically via `data.aws_ami` for the latest Amazon Linux 2023 (`al2023-ami-*-x86_64`). The subnet is resolved via `data.aws_subnets`, filtering `var.vpc_id` for subnets with `map-public-ip-on-launch = true`, and the first match is used.

**EC2 instance** — provisioned with the `terraform-aws-modules/ec2-instance/aws` module (v6.4.0). The key pair (`aws_key_pair.this`) is managed by Terraform from `var.public_key`, the root volume is encrypted, and a public IP is associated. `user_data_replace_on_change = true` means any change to `user_data.sh` or `web_server_count` triggers instance replacement on the next apply.

**User data** — `user_data.sh` is rendered with `templatefile()` and the `web_server_count` variable injected. At boot it installs Docker, starts the web server containers, generates the nginx upstream config, and starts the load balancer container. Only `${web_server_count}` is interpolated by Terraform; all bare `$VAR` references are plain shell variables.

**Security group** — a standalone `aws_security_group` with separate rule resources: ingress for HTTP (80) and HTTPS (443) from the internet, SSH (22) from `ssh_allowed_cidr`, and unrestricted egress (so the instance can pull Docker images at boot).

## Tooling & quality gates

- **tflint** — AWS ruleset plugin (`0.47.0`), configured in `.tflint.hcl`:
  ```bash
  tflint --init
  tflint --recursive
  ```
- **trivy** — security scanning of the Terraform config:
  ```bash
  trivy config .
  ```
- **pre-commit** — `terraform_fmt` runs on commit, `trivy` runs on push:
  ```bash
  pre-commit install
  pre-commit run --all-files
  ```

### Trivy suppressions

`.trivyignore` intentionally suppresses two findings:

- `AVD-AWS-0107` — HTTP/HTTPS open to the internet (expected for a public-facing load balancer)
- `AVD-AWS-0104` — unrestricted egress (required so the instance can pull Docker images at boot)

## CI/CD

GitHub Actions under `.github/workflows/`:

- **tflint** (`tflint.yml`) — runs on every push and PR. Failures block PRs but are allowed (non-blocking) on push.
- **Terraform Plan** (`terraform-plan.yml`) — runs on every PR, posts the plan as a PR comment (updating in place), and fails the check if the plan errors.
- **Terraform Apply** (`terraform-apply.yml`) — runs automatically on every push to `main` with `-auto-approve`.
- **Claude** (`claude.yml`, `claude-code-review.yml`) — automated code review/assistance.

### Required secrets & variables

Configured under **Settings → Environments → production**:

| Name | Type | Description |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | secret | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | secret | IAM secret key |
| `AWS_REGION` | variable | e.g. `il-central-1` |
| `TF_VAR_PUBLIC_KEY` | secret | SSH public key material, passed as `-var="public_key=..."` |
| `TF_VAR_SSH_ALLOWED_CIDR` | secret | passed as `-var="ssh_allowed_cidr=..."` |

## Security notes

- `*.tfvars` and `*.pem` are git-ignored by default. Note that `terraform.tfvars` is committed in this repo for convenience — review what you commit before pushing to a public remote.
- State is encrypted at rest in S3, and the bucket blocks all public access.
- SSH is restricted to `ssh_allowed_cidr`; HTTP/HTTPS are intentionally open to the world.
