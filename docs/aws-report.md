# AWS Deployment Report — Conduit on ECS Fargate

**Course:** DevOps — GitHub Actions / CI-CD  
**Application:** Conduit (RealWorld Medium clone)  
**Author:** nlnguyen  
**Date:** 2026-06-09  
**Region:** us-west-2 (Oregon)

---

## 1. Context & Objectives

Conduit is a full-stack reference application implementing the [RealWorld](https://realworld.io/) spec (a Medium clone). The codebase is an npm workspaces monorepo with two packages:

- **backend** — Express 5 REST API backed by PostgreSQL via Sequelize 6 ORM, exposing JWT-authenticated endpoints under `/api`.
- **frontend** — React 18 SPA built with Vite, served by an nginx container; all API calls hit relative `/api/…` paths.

Both services were already containerized as part of earlier DevOps work (Docker + docker-compose, Prometheus metrics, Grafana dashboards). The database credentials and JWT secret are fully env-driven through `config/config.js`.

**Course requirement:** deploy the application on AWS using a *custom multi-AZ VPC* with a robust, scalable, and least-privilege architecture. The architecture choice was free, but the VPC design (subnets, routing, security) is a mandatory deliverable. This report explains every choice made, the trade-offs considered, and the Terraform IaC used to implement it.

---

## 2. Architecture Choice Justification

Three deployment patterns were evaluated:

| Option | Verdict | Reasoning |
|--------|---------|-----------|
| **ECS Fargate + ALB + RDS** | **Chosen** | The app is already containerized — this is a 1:1 lift with zero rearchitecting. Fargate eliminates all OS/AMI patching. Multi-AZ and auto-scaling are built-in. Best effort-to-resilience ratio for this codebase. |
| EC2 Auto Scaling Group + ALB | Rejected | Introduces AMI/OS patching toil and launch-template complexity for no benefit at this scale. We would be managing servers to run containers, which is strictly inferior to Fargate. |
| Full serverless (Lambda + API Gateway) | Rejected | Express 5 combined with Sequelize's `sequelize.sync()` and connection-pool assumptions is not serverless-native. Adapting it would require a non-trivial rewrite using a wrapper like `serverless-http`, changing the database connection strategy, and testing cold-start behavior — none of which is warranted for a course project that already ships a working container. |

ECS Fargate was the clear choice: the containers run as-is, and the infrastructure adds multi-AZ placement, auto-scaling, and a managed control plane at no OS management overhead.

---

## 3. Network Design

### VPC Overview

A single VPC with CIDR `10.0.0.0/16` spans **two Availability Zones** (`us-west-2a` and `us-west-2b`). Traffic isolation is enforced by a strict three-tier subnet layout.

### Subnet Layout

| Tier | AZ | CIDR | Contents |
|------|----|------|----------|
| Public | us-west-2a | `10.0.0.0/24` | Application Load Balancer |
| Public | us-west-2b | `10.0.1.0/24` | Application Load Balancer |
| Private-app | us-west-2a | `10.0.10.0/24` | ECS Fargate tasks |
| Private-app | us-west-2b | `10.0.11.0/24` | ECS Fargate tasks |
| Private-data | us-west-2a | `10.0.20.0/24` | RDS PostgreSQL |
| Private-data | us-west-2b | `10.0.21.0/24` | RDS PostgreSQL |

### Routing

- **Public subnets** have an **Internet Gateway** route (`0.0.0.0/0 → igw`). Nodes in these subnets can be reached from the internet (ALB only).
- **Private-app and private-data subnets** share a single **private route table** that has **no default route** — there is no NAT Gateway.

### No-NAT Design and VPC Endpoints

The private subnets have no internet route. Instead, all AWS service access from the Fargate tasks is routed through **VPC endpoints**:

| Endpoint | Type | Purpose |
|----------|------|---------|
| `com.amazonaws.us-west-2.s3` | Gateway | ECR pulls Docker layer blobs from S3 — attaches to the private route table, no ENI cost |
| `com.amazonaws.us-west-2.ecr.api` | Interface | ECR registry API (describe, authenticate) |
| `com.amazonaws.us-west-2.ecr.dkr` | Interface | ECR Docker protocol (image pull) |
| `com.amazonaws.us-west-2.logs` | Interface | CloudWatch Logs (container stdout/stderr) |
| `com.amazonaws.us-west-2.secretsmanager` | Interface | Secrets Manager (DB credentials + JWT at task start) |

**Why no NAT?** The Conduit application makes no outbound internet calls at runtime — it only talks to RDS (private network) and pulls its image from ECR (VPC endpoint). A NAT Gateway would cost approximately $32/month per AZ (plus data-transfer) for traffic we never generate. Removing it also shrinks the attack surface: a misconfigured task cannot exfiltrate data or download malware from the internet. The trade-off is documented as an optional extension: if outbound internet is ever required, add a NAT Gateway per AZ and update the private route table.

---

## 4. Application Architecture

### ALB: Single Public Entry Point

The Application Load Balancer is deployed in the two public subnets. It is the **only internet-facing component** in the stack. All traffic enters through the ALB; no task or database is directly reachable from the internet.

**Path-based routing rule (priority 10):**

| Path pattern | Target group | Backend | Health check |
|-------------|--------------|---------|--------------|
| `/api/*` | `conduit-backend-tg` | Express `:3001` | `GET /api/tags → 200` |
| `/*` (default) | `conduit-frontend-tg` | nginx `:80` | `GET / → 200` |

Because the ALB intercepts `/api/*` before it ever reaches nginx, the nginx `proxy_pass` block for `/api` in the frontend container becomes inert — no application code change was required.

Both target groups have `deregistration_delay = 30` seconds, which ensures fast rolling deployments: tasks are drained and replaced within 30 seconds rather than the default 5 minutes.

### ECS Fargate Cluster

The cluster `conduit-cluster` runs two services in the private-app subnets:

| Service | Image | Port | `desired_count` | CPU | Memory |
|---------|-------|------|-----------------|-----|--------|
| `conduit-frontend` | `conduit-frontend:latest` from ECR | 80 | 2 | 256 vCPU units | 512 MB |
| `conduit-backend` | `conduit-backend:latest` from ECR | 3001 | 2 | 256 vCPU units | 512 MB |

Both services set `assign_public_ip = false` — tasks have only private IP addresses. Fargate places tasks across both AZs automatically using the two app subnets.

### RDS PostgreSQL (Multi-AZ)

| Parameter | Value |
|-----------|-------|
| Engine | PostgreSQL 16 |
| Instance class | `db.t4g.micro` |
| Storage | 20 GiB gp3, **`storage_encrypted = true`** |
| Multi-AZ | enabled (automatic standby in us-west-2b) |
| Publicly accessible | `false` |
| Backup retention | 1 day |
| Schema management | `sequelize.sync({ alter: true })` on backend boot |

The RDS primary and standby both live in the private-data subnets. No application code touches the RDS endpoint directly — credentials are injected via Secrets Manager (see §5).

---

## 5. Security & Least Privilege

### Security Group Chain

The network security model is a strict chain: each tier only accepts traffic from the tier immediately in front of it.

```
Internet
   │
   ▼
┌─────────────────────────────────────────┐
│  ALB-SG  (conduit-alb-sg)               │
│  Inbound: :80 from 0.0.0.0/0            │
│           :443 from 0.0.0.0/0 (future)  │
│  Outbound: all                          │
└──────────────┬──────────────────────────┘
               │ forwards to tasks
               ▼
┌─────────────────────────────────────────┐
│  tasks-SG  (conduit-tasks-sg)           │
│  Inbound: :80   only from ALB-SG        │
│           :3001 only from ALB-SG        │
│  Outbound: all (no NAT → VPC-only)      │
└────────────┬────────────┬───────────────┘
             │ DB conn    │ AWS APIs
             ▼            ▼
┌──────────────────┐  ┌──────────────────────────┐
│  rds-SG          │  │  vpce-SG (conduit-vpce-sg) │
│  Inbound: :5432  │  │  Inbound: :443             │
│  only from       │  │  only from tasks-SG        │
│  tasks-SG        │  └──────────────────────────┘
└──────────────────┘
```

No security group allows broad inbound from `0.0.0.0/0` except the ALB-SG on port 80 (and 443, pre-positioned for the HTTPS extension). A task that is somehow compromised cannot be reached from the internet, and it cannot reach the database unless it goes through the documented port 5432 from within the tasks-SG.

### IAM Role Split

The IAM model enforces **separation of concerns** between the ECS infrastructure agent and the application runtime:

**ECS Task Execution Role** (`conduit-ecs-execution`):
- Managed policy: `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy` — grants ECR pull permissions and CloudWatch Logs write permissions (standard Fargate bootstrapping).
- Inline policy (scoped): `secretsmanager:GetSecretValue` scoped to the single secret ARN `conduit/app` only. The execution role cannot read any other secret in the account.
- **Used by:** the ECS agent to set up the task (pull image, inject secrets, stream logs). The application process never receives this role's credentials.

**ECS Task Role** (`conduit-ecs-task`):
- No policies attached.
- **Used by:** the running application container at runtime.
- **Rationale:** Conduit talks only to RDS over the private network and does not call any AWS API during normal operation. Giving the task role zero permissions means that even if the application is compromised, it cannot access any AWS resource. This is the principle of least privilege applied at the IAM layer: grant only what is needed, which in this case is nothing.

#### Deployment-account reality: the LabRole fallback

The two-role split above is what the Terraform provisions **when run in an unrestricted AWS account** (`lab_role_arn = ""`). This project was, however, deployed in an **AWS Academy (`voclabs`) account**, where `iam:CreateRole` is denied — Terraform cannot create the dedicated execution and task roles. The module detects this case (`var.lab_role_arn` set) and falls back to the account's single pre-existing `LabRole` for both the execution role and the task role ([infra/modules/ecs/main.tf](../infra/modules/ecs/main.tf)).

This is an honest weakening of the IAM-layer least privilege: in the lab deployment one broad role is shared, rather than the scoped split. It is a **lab constraint, not a design choice** — in a normal account the split applies automatically with no code change. Crucially, the *network-layer* least privilege is unaffected: the tiered security-group chain, the three-tier subnet isolation, and the no-NAT egress containment (below) all hold regardless of which IAM role the tasks run as. The strongest guarantee — that a compromised task cannot be reached from the internet and cannot reach the database except through the one documented path — comes from the network design, which the lab does not constrain.

### Data Flows

**1. Request path (user to database):**
```
Client → Internet → ALB (public subnet)
       → frontend nginx (private-app subnet) [for SPA assets]
       → backend Express (private-app subnet) [for /api/* requests]
       → RDS PostgreSQL (private-data subnet)
```

Only the ALB is internet-facing. The database is unreachable from outside the VPC.

**2. Secrets path (credential injection at container start):**
```
ECS agent → Secrets Manager VPC endpoint (port 443, private)
          → injects PROD_DB_USERNAME, PROD_DB_PASSWORD, PROD_DB_NAME,
            PROD_DB_HOSTNAME, JWT_KEY as environment variables
          → backend container starts
```

Secrets are fetched by the ECS infrastructure agent before the container process starts. They appear only as environment variables inside the container. They are never in the Docker image, never written to a file, and never appear in the task definition in plaintext.

**3. Image pull and logging:**
```
ECS agent → ecr.api VPC endpoint (authenticate)
          → ecr.dkr + s3 VPC endpoints (pull image layers)
          → container stdout/stderr → logs VPC endpoint → CloudWatch Logs
```

All traffic to AWS services stays within the VPC, never traversing the internet.

---

## 6. Resilience & Scalability

### Multi-AZ Placement

Every component that supports Multi-AZ is deployed across `us-west-2a` and `us-west-2b`:

- **ALB** — spans both public subnets; AWS routes to a healthy AZ automatically.
- **ECS services** — `desired_count = 2` with tasks spread across both app subnets. Loss of one AZ leaves one running task per service.
- **RDS** — Multi-AZ enabled; AWS maintains a synchronous standby replica in `us-west-2b` (private-data subnet). Failover is automatic, typically completing in under 2 minutes.

### ECS Auto-Scaling (Backend)

The backend service has a target-tracking auto-scaling policy configured:

| Parameter | Value |
|-----------|-------|
| Metric | `ECSServiceAverageCPUUtilization` |
| Target value | 60% |
| Minimum capacity | 2 tasks |
| Maximum capacity | 4 tasks |

When average CPU across backend tasks exceeds 60% for a sustained period, ECS adds tasks (up to 4) automatically. When CPU drops, it scales back down to the minimum of 2. The frontend service does not have auto-scaling configured; it serves static assets and is not expected to be CPU-bound.

### ALB Health Checks and Rolling Deploys

ALB health checks run every 30 seconds against each registered target. A target is considered unhealthy after 3 consecutive failures and is immediately deregistered and replaced by ECS. The `deregistration_delay = 30` seconds on both target groups ensures that in-flight requests are gracefully drained before a task is stopped, keeping rolling deployments smooth and fast.

---

## 7. Observability & CI/CD

### CloudWatch Logs and Container Insights

Each service has a dedicated CloudWatch log group:

| Log group | Retention |
|-----------|-----------|
| `/ecs/conduit-frontend` | 7 days |
| `/ecs/conduit-backend` | 7 days |

The ECS cluster has `containerInsights = enabled`, which publishes per-task CPU, memory, network, and storage metrics to CloudWatch without additional instrumentation.

### Prometheus & Grafana

The backend already exposes a `/metrics` endpoint (added in the earlier monitoring work). The existing Prometheus scrape configuration and Grafana dashboards remain operational — they can scrape the backend tasks directly if Prometheus is reachable in the same VPC, or via the ALB path `/metrics` if exposed. This monitoring layer is decoupled from the Fargate deployment and is not on the critical path for this deliverable.

### CI/CD and Deployment Model

The repository's GitHub Actions pipeline (`.github/workflows/ci.yml`, `codeql.yml`) runs on every push: it installs dependencies, runs the Vitest suite, and performs CodeQL static analysis. **CI validates the application; it does not deploy.**

**Deployment is performed manually** by the operator running `terraform apply` with their own AWS credentials (see [infra/README.md](../infra/README.md)). This is a deliberate scope decision for the academy account, not a missing feature: federated CI deployment (GitHub OIDC → AWS) requires creating an IAM OIDC identity provider and a deploy role, and AWS Academy (`voclabs`) accounts **deny `iam:CreateRole` and `iam:CreateOpenIDConnectProvider`**. Shipping a workflow that cannot authenticate in the target account would be misleading, so deployment is operator-driven instead:

1. The operator sets temporary lab credentials and `lab_role_arn` (the account's `LabRole`) in `terraform.tfvars`.
2. `terraform apply -target=module.ecr` creates the image repositories.
3. Both images are built for `linux/amd64` (Fargate is x86_64) and pushed to ECR.
4. `terraform apply` provisions the VPC, RDS, ALB, and ECS services, which pull the images and roll out across both AZs.

The required ECS, ELB, and Application Auto Scaling **service-linked roles** are created automatically by Terraform on first apply (the academy account permits `iam:CreateServiceLinkedRole` even though it denies `iam:CreateRole`). In a normal account, the same Terraform also supports automated OIDC deployment with no code change.

### ECR Lifecycle Policy

Each ECR repository has a lifecycle policy that expires images when more than 10 exist (any tag status). This bounds repository storage cost and prevents unbounded growth from frequent CI pushes.

---

## 8. Cost & Teardown

### Estimated Costs While Running

| Component | Approximate cost |
|-----------|-----------------|
| Application Load Balancer | ~$0.70/day (LCU + hourly) |
| RDS `db.t4g.micro` Multi-AZ | ~$1.10/day |
| 4 interface VPC endpoints | ~$0.36/day (4 × $0.01/hr/AZ × 2 AZs) |
| ECS Fargate tasks (4 × 0.25vCPU/0.5GB) | ~$0.15/day (minimal) |
| **Total** | **~$2–3 USD/day** |

These are estimates; actual costs depend on traffic and data transfer. The provided AWS credentials are temporary STS tokens that expire; refresh them before running `terraform apply`.

### Teardown

Run from the `infra/` directory after the demo:

```bash
terraform destroy
```

Terraform will destroy in reverse dependency order: ECS services → ALB → RDS → VPC endpoints → subnets → VPC → ECR repositories (`force_delete = true` handles non-empty repos). Type `yes` to confirm. RDS deletion may take several minutes.

Verify cleanup:
```bash
aws ecs list-clusters --region us-west-2
aws rds describe-db-instances --region us-west-2
```

Both commands should return empty results for `conduit-*` resources.

**Note on Terraform state:** this project uses local state (`infra/terraform.tfstate`, gitignored). The state file is required to run `terraform destroy`. Do not delete it before teardown. Migrating to a remote backend (S3 + DynamoDB lock) is listed as an optional extension.

---

## 9. Architecture Diagram

```
                          ┌─────────────────────────────────────────────────────────┐
                          │  AWS VPC  10.0.0.0/16  —  us-west-2                     │
                          │                                                          │
  Internet                │  ┌────── Public Subnets ──────────────────────────────┐ │
     │                    │  │  10.0.0.0/24 (us-west-2a)  10.0.1.0/24 (us-west-2b)│ │
     │  :80               │  │                                                     │ │
     ▼                    │  │          ┌───────────────────┐                      │ │
  ──────────────────────► │  │          │  Application LB   │ ◄── IGW ◄── Internet │ │
                          │  │          │  (conduit-alb)    │                      │ │
                          │  └──────────┬──────────────────┬┘──────────────────── ┘ │
                          │             │ /api/*            │ /*                     │
                          │  ┌──────────▼──── Private-App Subnets ────────────────┐ │
                          │  │  10.0.10.0/24 (us-west-2a)  10.0.11.0/24 (b)       │ │
                          │  │                                                      │ │
                          │  │  ┌─────────────────┐   ┌──────────────────────┐     │ │
                          │  │  │ conduit-backend  │   │  conduit-frontend    │     │ │
                          │  │  │ (Express :3001)  │   │  (nginx :80)         │     │ │
                          │  │  │ ×2 tasks         │   │  ×2 tasks            │     │ │
                          │  │  └────────┬─────────┘   └──────────────────────┘     │ │
                          │  │           │ :5432                                     │ │
                          │  │           │         VPC Endpoints (no NAT):          │ │
                          │  │           │         ecr.api, ecr.dkr, s3 (gw)       │ │
                          │  │           │         logs, secretsmanager             │ │
                          │  └───────────┼───────────────────────────────────────── ┘ │
                          │             │                                             │
                          │  ┌──────────▼── Private-Data Subnets ────────────────┐   │
                          │  │  10.0.20.0/24 (us-west-2a)  10.0.21.0/24 (b)      │   │
                          │  │                                                    │   │
                          │  │  ┌─────────────────────────────────────────────┐  │   │
                          │  │  │  RDS PostgreSQL 16  (conduit-db)            │  │   │
                          │  │  │  Multi-AZ: primary (2a) + standby (2b)     │  │   │
                          │  │  │  storage_encrypted = true                  │  │   │
                          │  │  └─────────────────────────────────────────────┘  │   │
                          │  └────────────────────────────────────────────────── ┘   │
                          └─────────────────────────────────────────────────────────┘
```

**Secrets Manager** (accessed via VPC endpoint): stores `conduit/app` JSON with `PROD_DB_*` credentials and `JWT_KEY`. Injected into the backend task by the ECS execution role at container start.

---

## 10. Future Extensions

The following improvements are documented but not implemented in this academic deliverable:

1. **Remote Terraform state:** add an S3 bucket + DynamoDB lock table, then configure a `backend "s3"` block in `infra/providers.tf`. This enables team collaboration and prevents state file loss.

2. **HTTPS with ACM + Route 53:** request an ACM certificate for the domain, create a `:443` HTTPS listener on the ALB (the ALB-SG already pre-admits port 443), add an HTTP→HTTPS redirect on the `:80` listener, and create a Route 53 alias record pointing to the ALB DNS name.

3. **ALB access logs to S3:** enable ALB access logging to an S3 bucket for compliance and traffic analysis without increasing CloudWatch cost.

4. **NAT Gateway per AZ:** if the application ever requires outbound internet access (external API calls, OS package updates for debugging), add one NAT Gateway per AZ and update the private route table. Cost increases by ~$32/month/AZ.

5. **Prometheus & Grafana on ECS Fargate:** migrate the existing monitoring stack from docker-compose to additional Fargate services in the private-app subnets, scraping the backend's `/metrics` endpoint across the VPC.
