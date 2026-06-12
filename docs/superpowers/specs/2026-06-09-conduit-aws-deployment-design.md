# Conduit on AWS — Deployment Design (ECS Fargate)

- **Date:** 2026-06-09
- **App:** Conduit (RealWorld) — Express API + React SPA + PostgreSQL, npm workspaces monorepo, already containerized.
- **Goal:** Deploy on AWS with a custom multi-AZ VPC, on a robust/scalable/least-privilege architecture. Deliverable: Terraform IaC (applied by the author) + a report explaining the choices.
- **Scope decisions (confirmed):** Design + Terraform IaC (author applies) · ECS Fargate + ALB + RDS · Terraform · coupled with the existing DevOps work (GitHub Actions CI, Prometheus/Grafana) · keep nginx frontend on ECS · VPC endpoints (no NAT) · RDS Multi-AZ · HTTP-only ALB with a documented HTTPS path.

## 1. Why this architecture (rationale for the report)

The application is **already containerized** (`frontend` nginx image, `backend` Express image, `postgres`), with DB connection details fully env-driven and the SPA calling relative `/api/...` URLs. Given that starting point:

| Option | Verdict | Reason |
|--------|---------|--------|
| **ECS Fargate + ALB + RDS** | **Chosen** | 1:1 lift of the existing containers, no rearchitecting; multi-AZ + auto-scaling with no servers to patch. Best effort-to-resilience ratio. |
| EC2 Auto Scaling Group + ALB | Rejected | Adds AMI/OS patching and launch-template toil for no benefit at this scale. |
| Full serverless (Lambda + API GW) | Rejected | Express 5 + Sequelize (`sync`, connection pooling) is not serverless-native; would require an adapter and rework. |

## 2. Network design (custom VPC — hard requirement)

Single VPC `10.0.0.0/16`, spanning **2 Availability Zones** (e.g. `us-west-2a`, `us-west-2b`), with a 3-tier subnet layout per AZ:

| Tier | Subnets (per AZ) | Contents | Internet route |
|------|------------------|----------|----------------|
| Public | `10.0.0.0/24`, `10.0.1.0/24` | ALB | Internet Gateway |
| Private-app | `10.0.10.0/24`, `10.0.11.0/24` | ECS Fargate tasks (frontend, backend) | None (VPC endpoints only) |
| Private-data | `10.0.20.0/24`, `10.0.21.0/24` | RDS PostgreSQL | None |

- **Internet Gateway** attached to the VPC; public subnets route `0.0.0.0/0` to it.
- **No NAT Gateway.** Private subnets reach AWS services through **VPC endpoints**:
  - Interface endpoints: `ecr.api`, `ecr.dkr`, `logs` (CloudWatch), `secretsmanager`.
  - Gateway endpoint: `s3` (ECR pulls layer blobs from S3).
  - Rationale: the app makes no outbound internet calls, so NAT is unnecessary cost (~$32/mo+) and a wider attack surface. If outbound internet is ever needed, add a NAT Gateway per AZ. This is a deliberate cost/security trade-off to highlight in the report.

## 3. Application tiers

- **ALB** (public subnets): the only public entry point. HTTP-only for the academic demo; HTTPS documented as an extension (ACM cert + Route 53 + a `:443` listener + HTTP→HTTPS redirect).
- **ALB routing (path-based):**
  - `/api/*` → **backend** target group (Express `:3001`), health check `GET /api/tags`.
  - `/*` → **frontend** target group (nginx `:80`), health check `GET /`.
  - The nginx container's internal `/api` `proxy_pass` becomes inert because the ALB intercepts `/api` before it reaches nginx — **no application code change required.**
- **ECS Fargate cluster** with two services in private-app subnets:
  - `frontend` — existing nginx image, `desired_count = 2`, tasks spread across both AZs.
  - `backend` — existing Express image, `desired_count = 2`, tasks spread across both AZs.
  - Images pulled from **ECR** (one repository per image).
- **RDS PostgreSQL, Multi-AZ**, in private-data subnets, `publicly_accessible = false`, automated backups on. Replaces the Postgres container. `db.t4g.micro` (or `t3.micro`) is sufficient.
  - Schema: the backend's `sequelize.sync({ alter: true })` creates tables on boot; the Sequelize seeder is run once to load demo data.
  - Credentials generated and stored in **Secrets Manager**, injected into the backend task definition as secret env vars (`PROD_DB_*`). `JWT_KEY` also stored in Secrets Manager.

## 4. Least-privilege flows (graded section)

### Security-group chain (each SG accepts only from the previous one)

```
Internet ──► ALB-SG        ( :80/:443 from 0.0.0.0/0 )
          ──► tasks-SG      ( frontend :80 and backend :3001, only from ALB-SG )
          ──► RDS-SG        ( :5432, only from tasks-SG )
```

VPC-endpoint SG allows `:443` only from `tasks-SG`. No SG allows broad inbound from the internet except the ALB.

### IAM role split

- **ECS task execution role** — pull from ECR, read the DB/JWT secrets from Secrets Manager, write logs to CloudWatch. Used by the ECS agent to start the task.
- **ECS task role** — runtime permissions for the app itself; minimal (effectively none, as the app talks only to RDS over the network). Kept separate so app code never inherits infra permissions.
- **CI/CD deploy role** — assumed by GitHub Actions via **OIDC** (no long-lived keys); scoped to ECR push + `ecs:UpdateService` + `iam:PassRole` for the task roles only.

### Data flows

1. **Request path:** client → ALB (public) → frontend nginx OR backend Express (private-app) → RDS (private-data). Only the ALB is internet-facing.
2. **Secrets path:** backend task → Secrets Manager VPC endpoint → injected at container start. Secrets never appear in the task definition in plaintext or in the image.
3. **Image pull / logs:** task → ECR + S3 + CloudWatch Logs VPC endpoints, entirely inside the VPC.

## 5. Resilience & scaling

- **Multi-AZ everywhere:** subnets, ALB, ECS task placement, and RDS standby all span 2 AZs. Loss of one AZ leaves a working stack.
- **ECS service auto-scaling:** target-tracking on CPU/memory (and optionally ALB request count per target) to scale task count under load.
- **ALB health checks** drain and replace unhealthy tasks automatically.
- **RDS Multi-AZ** provides automatic failover to the standby replica.

## 6. Observability

- **CloudWatch Logs** (one log group per service) + **Container Insights** for cluster/task metrics.
- **Application metrics:** keep the existing Prometheus/Grafana layer (the backend already exposes `/metrics`). It can run as a small additional ECS service or stay external; not on the critical path for this deliverable.

## 7. CI/CD coupling (existing GitHub Actions)

Extend the current workflows to add a deploy stage on the default branch:
1. Build `frontend` and `backend` images.
2. Authenticate to AWS via **OIDC** (assume the scoped deploy role — no static credentials in GitHub).
3. Push images to ECR.
4. `aws ecs update-service --force-new-deployment` for each service (rolling deployment).

## 8. Terraform structure (for the implementation plan)

```
infra/
  providers.tf        # AWS provider, backend (state), region
  variables.tf        # region, AZ list, CIDRs, image tags, instance sizes
  main.tf             # wires the modules together
  outputs.tf          # ALB DNS name, ECR repo URLs, RDS endpoint
  modules/
    network/          # VPC, 6 subnets, route tables, IGW, VPC endpoints, all SGs
    ecr/              # 2 repositories
    alb/              # ALB, listener(s), 2 target groups, path rules
    ecs/              # cluster, 2 task definitions, 2 services, IAM roles, autoscaling
    rds/              # subnet group, Multi-AZ instance, Secrets Manager secret + version
```

State backend (S3 + DynamoDB lock) is optional for an academic project; local state is acceptable and simpler — note the trade-off in the report.

## 9. Cost & teardown note

ALB + Multi-AZ RDS + interface VPC endpoints incur real hourly cost (~a few USD/day). The author applies and destroys; run `terraform destroy` after the demo. The provided AWS credentials are temporary STS tokens and will expire.

## 10. Report outline (deliverable)

1. Context & objectives.
2. Architecture choice justification (ECS vs serverless vs ASG — §1).
3. Network design: VPC, subnets, AZs, routing, no-NAT trade-off (§2).
4. Application architecture: ALB routing, ECS services, RDS (§3).
5. Security & least privilege: SG chain, IAM role split, data flows (§4).
6. Resilience & scalability (§5).
7. Observability & CI/CD (§6–7).
8. Cost considerations & teardown (§9).
9. Diagram (topology from §2/§3).
