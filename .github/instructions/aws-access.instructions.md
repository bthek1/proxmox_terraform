---
description: "Use when accessing AWS, logging into AWS SSO, checking AWS session status, connecting to EC2, running AWS CLI commands, or setting up and managing the AWS account. Covers authentication, profile usage, EC2 access, account management, IAM roles, S3, networking, and resource inventory."
---
# AWS Setup & Management Guide

## Project Purpose

This project (`AWS_setup`) is used to **set up and manage an AWS account**. It provides tooling, scripts, and configuration for:
- AWS SSO authentication
- EC2 instance access and provisioning
- AWS account and organization management
- Infrastructure provisioning and configuration
- S3 static website hosting and deployment
- IAM roles and policies management
- GitHub Actions CI/CD integration via OIDC
- GitHub repository and workflow management (see [github-cli.instructions.md](./github-cli.instructions.md))

Detailed per-resource documentation lives in `Docs/`:
- `Docs/AWS_info/aws-resources.md` — full resource inventory
- `Docs/AWS_info/identity.md` — account, SSO, Organizations, OIDC
- `Docs/AWS_info/networking.md` — VPC, subnets, security groups, routing
- `Docs/AWS_info/ec2.md` — EC2 instances and launch configuration
- `Docs/AWS_info/s3.md` — S3 buckets and static website hosting
- `Docs/AWS_info/iam.md` — IAM roles and policies
- `Docs/AWS_info/lambda.md` — Lambda functions
- `Docs/AWS_info/rds.md` — RDS databases

---

# AWS Access Guide

## Account Configuration

| Variable | Value |
|----------|-------|
| AWS Account ID | `762233760445` |
| AWS Profile | `ben-sso` |
| Region | `ap-southeast-2` (Sydney) |
| SSO User | `benthekkel` |
| SSO Instance | `ssoins-82591beaa0a405e4` |
| Organization ID | `o-cb9ltcw3me` |

> **EC2:** Current instance is `wireguard-server` (`i-02abf2da13b3858c7`, EIP `3.104.200.207`, running). See [Docs/AWS_info/ec2.md](../../Docs/AWS_info/ec2.md) for up-to-date details. The previously referenced instance `i-0b743f46aa5f97190` has been terminated.

All AWS CLI commands use `--profile ben-sso`. Always set `AWS_PAGER=""` or pipe to `| cat` to avoid interactive pagers blocking output.

## Authentication — AWS SSO Login

Run via `just`:
```bash
just aws-login
```

Or directly:
```bash
aws sso login --profile ben-sso
```

This opens a browser for SSO authorization. Complete the login in the browser. The session remains valid until it expires (typically 8–12 hours).

## Check Session Status

```bash
just aws-status
```

Or directly:
```bash
aws sts get-caller-identity --profile ben-sso
```

A successful response returns your `UserId`, `Account`, and `Arn`. An error means the session has expired — re-run `just aws-login`.

## Open AWS Console

```bash
just aws-console
```

This logs in via SSO and attempts to open the AWS SSO Start URL in the default browser (`xdg-open` on Linux).

## AWS CLI Usage Pattern

Always pass `--profile ben-sso` to every AWS CLI command. Set `AWS_PAGER=""` to prevent output from opening a pager:

```bash
AWS_PAGER="" aws <service> <command> --profile ben-sso
# Examples:
AWS_PAGER="" aws s3 ls --profile ben-sso
AWS_PAGER="" aws ec2 describe-instances --profile ben-sso
AWS_PAGER="" aws iam list-roles --profile ben-sso
```

## Active AWS Resources

### Networking (ap-southeast-2)
| Resource | ID | Details |
|----------|----|---------|
| VPC | `vpc-098c20fa9385bb6e1` | Default VPC, `172.31.0.0/16` |
| Subnet (2a) | `subnet-0e7fee3257a202c50` | `172.31.0.0/20` |
| Subnet (2b) | `subnet-0f2d2d33fa45bd940` | `172.31.32.0/20` |
| Subnet (2c) | `subnet-0e1ec423c307c9ed7` | `172.31.16.0/20` |
| Internet Gateway | `igw-00817a636c9d7afd8` | Attached to VPC |
| Route Table | `rtb-08519e479d428628c` | Main, routes to IGW |
| Security Group | `sg-02f7d8026da10a82f` | Ports 22/80/443 open |

### S3
| Bucket | Region | Purpose |
|--------|--------|---------|
| `weather.benedictthekkel.com` | `us-east-1` | Static website (Vite SPA) |

### IAM Roles
| Role | Purpose |
|------|---------|
| `github-actions-role` | GitHub Actions OIDC CI/CD (repo: `bthek1/ISO_Standards`, branch: `main`) |
| `ISO-Standards-EC2-Role` | EC2 instance profile with `ISO-Standards-Secrets-Read` policy |

## EC2 Access

No instances are currently running. To connect when an instance is running, use SSM Session Manager (no SSH key required):

```bash
aws ssm start-session --target <INSTANCE_ID> --profile ben-sso
```

To launch a new instance using the existing IAM role and security group:
```bash
AWS_PAGER="" aws ec2 run-instances \
  --image-id ami-0310483fb2b488153 \
  --instance-type t3.micro \
  --subnet-id subnet-0e7fee3257a202c50 \
  --security-group-ids sg-02f7d8026da10a82f \
  --iam-instance-profile Name=ISO-Standards-EC2-Role \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ISO-Standards}]' \
  --profile ben-sso
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Error loading SSO Token` | Run `just aws-login` to re-authenticate |
| `ExpiredTokenException` | Session expired — run `just aws-login` |
| `NoCredentialProviders` | Missing `--profile ben-sso` flag |
| Browser does not open | Manually visit the URL printed in the terminal |
| Output opens a pager | Prefix command with `AWS_PAGER=""` or append `\| cat` |
| SSM session fails | Ensure the EC2 instance is running: `AWS_PAGER="" aws ec2 describe-instances --profile ben-sso` |

