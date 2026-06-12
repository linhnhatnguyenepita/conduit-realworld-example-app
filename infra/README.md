# Conduit on AWS — Infrastructure (Terraform)

Terraform that deploys the Conduit app to AWS on **ECS Fargate** behind an
**Application Load Balancer**, backed by **Multi-AZ RDS PostgreSQL**, inside a
**custom multi-AZ VPC**. Everything is applied manually with your own AWS
credentials — there is no external automation to configure.

The full design rationale and the least-privilege flows are in
[`docs/rapport-aws.html`](../docs/rapport-aws.html).

## AWS architecture (in short)

```
Internet
   │  :80
   ▼
[ ALB ]  public subnets, 2 AZs  ── only internet-facing component
   │   /api/* → backend TG          /* → frontend TG
   ▼
[ ECS Fargate ]  private "app" subnets, 2 AZs
   ├─ frontend (nginx)  ×2   serves the React SPA
   └─ backend (Express) ×2→4 autoscaled on CPU
   │  :5432 (TLS)
   ▼
[ RDS PostgreSQL 16 ]  private "data" subnets, Multi-AZ (primary + standby)
```

- **Network** — one VPC (`10.0.0.0/16`) over 2 AZs, split into 3 subnet tiers:
  public (ALB), private-app (ECS tasks), private-data (RDS). No NAT Gateway; the
  app reaches AWS services through **VPC endpoints** (ECR, S3, CloudWatch Logs,
  Secrets Manager), so nothing in the private tiers touches the internet.
- **Least privilege** — a security-group chain where each tier only accepts
  traffic from the tier in front of it (Internet→ALB→tasks→RDS). RDS is private
  and encrypted; DB credentials + JWT key live in **Secrets Manager** and are
  injected into the backend container at startup.
- **Resilience / scale** — ALB, ECS tasks, and RDS all span 2 AZs; the backend
  has CPU target-tracking autoscaling (2→4 tasks).

## Terraform structure

Composed of small, single-purpose modules wired together in [`main.tf`](main.tf):

| Module | Responsibility |
|---|---|
| `modules/network` | VPC, subnets (3 tiers × 2 AZs), routing, security groups, VPC endpoints |
| `modules/ecr`     | Container image repositories + lifecycle policy |
| `modules/rds`     | Multi-AZ PostgreSQL + Secrets Manager secret |
| `modules/alb`     | Load balancer, target groups, path-based listener rules |
| `modules/ecs`     | Fargate cluster, task definitions, services, autoscaling, IAM/log groups |

Inputs are in [`variables.tf`](variables.tf); outputs (ALB DNS, repo URLs,
RDS endpoint) in [`outputs.tf`](outputs.tf). State is local (`terraform.tfstate`,
gitignored) — keep it until you tear down.

## Prerequisites

- Terraform ≥ 1.5, Docker, AWS CLI v2
- AWS credentials with permission to create VPC/ECS/RDS/ALB/ECR/Secrets/CloudWatch
  (an AWS Academy `LabRole` account works — see note below)

## Step 1 — Set your AWS credentials and region

Use **your own** credentials. In an AWS Academy lab, open **AWS Details → AWS CLI**
and paste the block into `~/.aws/credentials` (these are temporary and expire —
refresh them each session). Then set the region and confirm:

```bash
aws configure set region us-west-2
aws sts get-caller-identity        # must print your account — confirms creds work
```

> **Academy accounts:** they deny `iam:CreateRole`. Terraform handles this
> automatically — it reuses the account's pre-existing `LabRole` for the ECS
> roles, **auto-derived from your account ID**. You don't need to configure
> anything. (No `terraform.tfvars` is required at all; the JWT key is also
> auto-generated.)

## Step 2 — Create the image repositories

ECS can't start tasks before the images exist, so create ECR first:

```bash
cd infra
terraform init
terraform apply -target=module.ecr
```

## Step 3 — Build and push the images

Fargate runs **x86_64**, so on Apple Silicon you **must** build `linux/amd64`
(otherwise tasks crash with "exec format error"). Build from the repo root:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2
ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR

docker build --platform linux/amd64 -f backend/Dockerfile  -t $ECR/conduit-backend:latest  ..
docker build --platform linux/amd64 -f frontend/Dockerfile -t $ECR/conduit-frontend:latest ..
docker push $ECR/conduit-backend:latest
docker push $ECR/conduit-frontend:latest
```

## Step 4 — Deploy the rest

```bash
terraform apply        # VPC, RDS Multi-AZ (~10–15 min), ALB, ECS services
```

If a temporary token expires mid-apply, refresh the credentials and re-run
`terraform apply` — it is idempotent and local state is preserved.

## Step 5 — Verify

```bash
URL="http://$(terraform output -raw alb_dns_name)"
curl -I "$URL/"            # React SPA  → 200
curl    "$URL/api/tags"    # backend + RDS → JSON
```

## Teardown

```bash
terraform destroy
```

Keep `terraform.tfstate` until the destroy completes. Verify nothing remains:

```bash
aws ecs list-clusters --region us-west-2
aws rds describe-db-instances --region us-west-2
```
