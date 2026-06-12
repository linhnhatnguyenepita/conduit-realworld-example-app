# Conduit AWS Deployment (ECS Fargate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision the Conduit app on AWS via Terraform — a custom multi-AZ VPC, ECS Fargate (frontend nginx + backend Express), an Application Load Balancer, and a Multi-AZ RDS PostgreSQL — then deploy the existing container images and wire it into the existing GitHub Actions CI/CD.

**Architecture:** A single VPC across 2 AZs with public / private-app / private-data subnet tiers. The ALB in public subnets path-routes `/api/*` to the backend Fargate service and `/*` to the frontend Fargate service. Tasks run in private subnets with no NAT — egress to AWS services is via VPC endpoints. RDS PostgreSQL Multi-AZ lives in isolated data subnets, credentials in Secrets Manager. A least-privilege security-group chain (ALB → tasks → RDS) and split IAM roles enforce flow control.

**Tech Stack:** Terraform (AWS provider ~> 5.x), AWS (VPC, ECS Fargate, ALB, RDS, ECR, Secrets Manager, CloudWatch, VPC endpoints, IAM/OIDC), Docker, GitHub Actions.

**Spec:** [docs/superpowers/specs/2026-06-09-conduit-aws-deployment-design.md](../specs/2026-06-09-conduit-aws-deployment-design.md)

---

## Conventions

- **Region:** `us-west-2`. **Project name:** `conduit`. All names/tags prefixed `conduit-`.
- **Working dir for all `terraform` commands:** `infra/`.
- **State:** local (`infra/terraform.tfstate`), gitignored. Remote backend is an optional extension (see Task 11).
- **The implementer never runs `terraform apply` unprovoked.** `validate` and `plan` are safe and run freely; `apply`/`destroy` happen only in the gated Task 9 and Task 12, with the human confirming.
- After each module file, run `terraform fmt` and `terraform validate` from `infra/`, then commit. (The first `validate` requires `terraform init` — Task 1 Step 1.)

## File Structure

```
infra/
  .gitignore          # ignore .terraform/, *.tfstate*, *.tfvars (secrets)
  providers.tf        # AWS provider + required_versions, region
  variables.tf        # region, project, azs, cidrs, image tags, db/instance sizing
  terraform.tfvars    # concrete values (gitignored)
  main.tf             # wires modules together, passes outputs between them
  outputs.tf          # alb_dns_name, ecr repo urls, rds_endpoint
  modules/
    network/          # VPC, 6 subnets, IGW, route tables, VPC endpoints, all SGs
      main.tf  variables.tf  outputs.tf
    ecr/              # frontend + backend repositories
      main.tf  variables.tf  outputs.tf
    rds/              # subnet group, Secrets Manager secret, Multi-AZ instance
      main.tf  variables.tf  outputs.tf
    alb/              # ALB, 2 target groups, HTTP listener + path rule
      main.tf  variables.tf  outputs.tf
    ecs/              # cluster, IAM roles, 2 task defs, 2 services, autoscaling, log groups
      main.tf  variables.tf  outputs.tf
.github/workflows/
  deploy-aws.yml      # build → ECR push → ecs update-service (OIDC)
docs/aws-report.md    # the graded report (Task 10)
```

---

## Task 1: Scaffold Terraform root (providers, variables, gitignore)

**Files:**
- Create: `infra/.gitignore`, `infra/providers.tf`, `infra/variables.tf`, `infra/terraform.tfvars`

- [ ] **Step 1: Create `infra/.gitignore`**

```gitignore
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfvars
crash.log
```

- [ ] **Step 2: Create `infra/providers.tf`**

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
```

- [ ] **Step 3: Create `infra/variables.tf`**

```hcl
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "project" {
  type    = string
  default = "conduit"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "data_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "frontend_image_tag" {
  type    = string
  default = "latest"
}

variable "backend_image_tag" {
  type    = string
  default = "latest"
}

variable "db_name" {
  type    = string
  default = "conduit"
}

variable "db_username" {
  type    = string
  default = "conduit"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "jwt_key" {
  type      = string
  sensitive = true
}
```

- [ ] **Step 4: Create `infra/terraform.tfvars`** (gitignored — real values)

```hcl
region  = "us-west-2"
project = "conduit"
jwt_key = "change-me-to-a-long-random-string"
```

- [ ] **Step 5: Commit**

```bash
git add infra/.gitignore infra/providers.tf infra/variables.tf
git commit -m "infra: scaffold terraform root (providers, variables)"
```
(Note: `terraform.tfvars` is intentionally not committed — it is gitignored.)

---

## Task 2: Network module (VPC, subnets, routing, endpoints, security groups)

**Files:**
- Create: `infra/modules/network/variables.tf`, `infra/modules/network/main.tf`, `infra/modules/network/outputs.tf`

- [ ] **Step 1: Create `infra/modules/network/variables.tf`**

```hcl
variable "project" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }
variable "public_subnet_cidrs" { type = list(string) }
variable "app_subnet_cidrs" { type = list(string) }
variable "data_subnet_cidrs" { type = list(string) }
```

- [ ] **Step 2: Create `infra/modules/network/main.tf`** (VPC, subnets, IGW, routes)

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = length(var.app_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-app-${var.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "data" {
  count             = length(var.data_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-data-${var.azs[count.index]}", Tier = "private-data" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table: no internet route (no NAT). S3 gateway endpoint attaches here.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count          = length(aws_subnet.data)
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private.id
}
```

- [ ] **Step 3: Append security groups to `infra/modules/network/main.tf`**

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB: public HTTP/HTTPS in"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-alb-sg" }
}

resource "aws_security_group" "tasks" {
  name        = "${var.project}-tasks-sg"
  description = "Fargate tasks: app ports only from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "frontend nginx"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description     = "backend express"
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-tasks-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "RDS: postgres only from tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "postgres"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
  tags = { Name = "${var.project}-rds-sg" }
}

resource "aws_security_group" "vpce" {
  name        = "${var.project}-vpce-sg"
  description = "VPC interface endpoints: HTTPS from tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTPS from tasks"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
  tags = { Name = "${var.project}-vpce-sg" }
}
```

- [ ] **Step 4: Append VPC endpoints to `infra/modules/network/main.tf`**

```hcl
# S3 gateway endpoint (ECR pulls layer blobs from S3) — attaches to the private route table.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.project}-s3-vpce" }
}

# Interface endpoints for ECR, logs, secrets — in the app subnets, reachable from tasks.
locals {
  interface_endpoints = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "${var.project}-${each.value}-vpce" }
}
```

- [ ] **Step 5: Create `infra/modules/network/outputs.tf`**

```hcl
output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "app_subnet_ids" { value = aws_subnet.app[*].id }
output "data_subnet_ids" { value = aws_subnet.data[*].id }
output "alb_sg_id" { value = aws_security_group.alb.id }
output "tasks_sg_id" { value = aws_security_group.tasks.id }
output "rds_sg_id" { value = aws_security_group.rds.id }
```

- [ ] **Step 6: `terraform init` and validate** (module not yet referenced — validate after Task 7 wiring; for now just fmt)

Run: `cd infra && terraform fmt -recursive`
Expected: lists reformatted files (or nothing). No error.

- [ ] **Step 7: Commit**

```bash
git add infra/modules/network/
git commit -m "infra: add network module (vpc, subnets, sgs, vpc endpoints)"
```

---

## Task 3: ECR module

**Files:**
- Create: `infra/modules/ecr/variables.tf`, `infra/modules/ecr/main.tf`, `infra/modules/ecr/outputs.tf`

- [ ] **Step 1: Create `infra/modules/ecr/variables.tf`**

```hcl
variable "project" { type = string }
```

- [ ] **Step 2: Create `infra/modules/ecr/main.tf`**

```hcl
locals {
  repos = ["frontend", "backend"]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(local.repos)
  name                 = "${var.project}-${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = { Name = "${var.project}-${each.value}" }
}
```

- [ ] **Step 3: Create `infra/modules/ecr/outputs.tf`**

```hcl
output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
output "frontend_repo_url" { value = aws_ecr_repository.this["frontend"].repository_url }
output "backend_repo_url" { value = aws_ecr_repository.this["backend"].repository_url }
```

- [ ] **Step 4: fmt + commit**

```bash
cd infra && terraform fmt -recursive && cd ..
git add infra/modules/ecr/
git commit -m "infra: add ecr module (frontend + backend repos)"
```

---

## Task 4: RDS module (subnet group, Secrets Manager, Multi-AZ instance)

**Files:**
- Create: `infra/modules/rds/variables.tf`, `infra/modules/rds/main.tf`, `infra/modules/rds/outputs.tf`

- [ ] **Step 1: Create `infra/modules/rds/variables.tf`**

```hcl
variable "project" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "db_instance_class" { type = string }
variable "subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "jwt_key" {
  type      = string
  sensitive = true
}
```

- [ ] **Step 2: Create `infra/modules/rds/main.tf`**

```hcl
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.project}-db-subnets" }
}

resource "aws_db_instance" "this" {
  identifier              = "${var.project}-db"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  db_name                 = var.db_name
  username                = var.db_username
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [var.rds_sg_id]
  multi_az                = true
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 1
  deletion_protection     = false
  tags                    = { Name = "${var.project}-db" }
}

# Store DB connection + JWT as a single JSON secret for the backend task.
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/app"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    PROD_DB_USERNAME = var.db_username
    PROD_DB_PASSWORD = random_password.db.result
    PROD_DB_NAME     = var.db_name
    PROD_DB_HOSTNAME = aws_db_instance.this.address
    JWT_KEY          = var.jwt_key
  })
}
```

- [ ] **Step 3: Create `infra/modules/rds/outputs.tf`**

```hcl
output "endpoint" { value = aws_db_instance.this.address }
output "secret_arn" { value = aws_secretsmanager_secret.app.arn }
```

- [ ] **Step 4: Add the `random` provider** to `infra/providers.tf` `required_providers`:

```hcl
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
```

- [ ] **Step 5: fmt + commit**

```bash
cd infra && terraform fmt -recursive && cd ..
git add infra/modules/rds/ infra/providers.tf
git commit -m "infra: add rds module (multi-az postgres + secrets manager)"
```

---

## Task 5: ALB module (load balancer, target groups, listener, path rule)

**Files:**
- Create: `infra/modules/alb/variables.tf`, `infra/modules/alb/main.tf`, `infra/modules/alb/outputs.tf`

- [ ] **Step 1: Create `infra/modules/alb/variables.tf`**

```hcl
variable "project" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
```

- [ ] **Step 2: Create `infra/modules/alb/main.tf`**

```hcl
resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids
  tags               = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.project}-frontend-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { Name = "${var.project}-frontend-tg" }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project}-backend-tg"
  port        = 3001
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    path                = "/api/tags"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { Name = "${var.project}-backend-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Default: serve the SPA.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# /api/* goes to the backend.
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
```

- [ ] **Step 3: Create `infra/modules/alb/outputs.tf`**

```hcl
output "dns_name" { value = aws_lb.this.dns_name }
output "frontend_tg_arn" { value = aws_lb_target_group.frontend.arn }
output "backend_tg_arn" { value = aws_lb_target_group.backend.arn }
```

- [ ] **Step 4: fmt + commit**

```bash
cd infra && terraform fmt -recursive && cd ..
git add infra/modules/alb/
git commit -m "infra: add alb module (path-based routing to frontend/backend)"
```

---

## Task 6: ECS module (cluster, IAM roles, task defs, services, autoscaling)

**Files:**
- Create: `infra/modules/ecs/variables.tf`, `infra/modules/ecs/main.tf`, `infra/modules/ecs/outputs.tf`

- [ ] **Step 1: Create `infra/modules/ecs/variables.tf`**

```hcl
variable "project" { type = string }
variable "region" { type = string }
variable "app_subnet_ids" { type = list(string) }
variable "tasks_sg_id" { type = string }
variable "frontend_image" { type = string }
variable "backend_image" { type = string }
variable "frontend_tg_arn" { type = string }
variable "backend_tg_arn" { type = string }
variable "secret_arn" { type = string }
```

- [ ] **Step 2: Create `infra/modules/ecs/main.tf`** — cluster, log groups, IAM roles

```hcl
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read the app secret only.
data "aws_iam_policy_document" "read_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secret" {
  name   = "${var.project}-read-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secret.json
}

# Task role: app runtime perms — none needed (app only talks to RDS over the network).
resource "aws_iam_role" "task" {
  name               = "${var.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${var.project}-frontend"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project}-backend"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
```

- [ ] **Step 3: Append task definitions to `infra/modules/ecs/main.tf`**

```hcl
resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = var.frontend_image
      essential = true
      portMappings = [{ containerPort = 80, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.frontend.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "frontend"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = var.backend_image
      essential = true
      portMappings = [{ containerPort = 3001, protocol = "tcp" }]
      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "PORT", value = "3001" },
        { name = "PROD_DB_DIALECT", value = "postgres" },
        { name = "PROD_DB_LOGGING", value = "false" }
      ]
      secrets = [
        { name = "PROD_DB_USERNAME", valueFrom = "${var.secret_arn}:PROD_DB_USERNAME::" },
        { name = "PROD_DB_PASSWORD", valueFrom = "${var.secret_arn}:PROD_DB_PASSWORD::" },
        { name = "PROD_DB_NAME", valueFrom = "${var.secret_arn}:PROD_DB_NAME::" },
        { name = "PROD_DB_HOSTNAME", valueFrom = "${var.secret_arn}:PROD_DB_HOSTNAME::" },
        { name = "JWT_KEY", valueFrom = "${var.secret_arn}:JWT_KEY::" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])
}
```

- [ ] **Step 4: Append services + autoscaling to `infra/modules/ecs/main.tf`**

```hcl
resource "aws_ecs_service" "frontend" {
  name            = "${var.project}-frontend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.tasks_sg_id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = var.frontend_tg_arn
    container_name   = "frontend"
    container_port   = 80
  }
}

resource "aws_ecs_service" "backend" {
  name            = "${var.project}-backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.tasks_sg_id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = var.backend_tg_arn
    container_name   = "backend"
    container_port   = 3001
  }
}

# Auto-scaling: target-track CPU at 60% for the backend.
resource "aws_appautoscaling_target" "backend" {
  max_capacity       = 4
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${var.project}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 60
  }
}
```

- [ ] **Step 5: Create `infra/modules/ecs/outputs.tf`**

```hcl
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "frontend_service" { value = aws_ecs_service.frontend.name }
output "backend_service" { value = aws_ecs_service.backend.name }
```

- [ ] **Step 6: fmt + commit**

```bash
cd infra && terraform fmt -recursive && cd ..
git add infra/modules/ecs/
git commit -m "infra: add ecs module (cluster, iam, task defs, services, autoscaling)"
```

---

## Task 7: Wire modules in the root (main.tf, outputs.tf) and validate

**Files:**
- Create: `infra/main.tf`, `infra/outputs.tf`

- [ ] **Step 1: Create `infra/main.tf`**

```hcl
module "network" {
  source              = "./modules/network"
  project             = var.project
  region              = var.region
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  data_subnet_cidrs   = var.data_subnet_cidrs
}

module "ecr" {
  source  = "./modules/ecr"
  project = var.project
}

module "rds" {
  source            = "./modules/rds"
  project           = var.project
  db_name           = var.db_name
  db_username       = var.db_username
  db_instance_class = var.db_instance_class
  subnet_ids        = module.network.data_subnet_ids
  rds_sg_id         = module.network.rds_sg_id
  jwt_key           = var.jwt_key
}

module "alb" {
  source            = "./modules/alb"
  project           = var.project
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.network.alb_sg_id
}

module "ecs" {
  source          = "./modules/ecs"
  project         = var.project
  region          = var.region
  app_subnet_ids  = module.network.app_subnet_ids
  tasks_sg_id     = module.network.tasks_sg_id
  frontend_image  = "${module.ecr.frontend_repo_url}:${var.frontend_image_tag}"
  backend_image   = "${module.ecr.backend_repo_url}:${var.backend_image_tag}"
  frontend_tg_arn = module.alb.frontend_tg_arn
  backend_tg_arn  = module.alb.backend_tg_arn
  secret_arn      = module.rds.secret_arn
}
```

- [ ] **Step 2: Create `infra/outputs.tf`**

```hcl
output "alb_dns_name" { value = module.alb.dns_name }
output "frontend_repo_url" { value = module.ecr.frontend_repo_url }
output "backend_repo_url" { value = module.ecr.backend_repo_url }
output "rds_endpoint" { value = module.rds.endpoint }
output "ecs_cluster" { value = module.ecs.cluster_name }
```

- [ ] **Step 3: Init + validate** (configure AWS creds first, see Task 9 prereqs)

Run: `cd infra && terraform init && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: fmt + commit**

```bash
cd infra && terraform fmt -recursive && cd ..
git add infra/main.tf infra/outputs.tf
git commit -m "infra: wire modules in root and validate"
```

---

## Task 8: Bootstrap apply — ECR + network only, then build & push images

> Images must exist in ECR before ECS services can start. This task applies the ECR repos first, pushes images, then the full apply happens in Task 9.

- [ ] **Step 1: Confirm AWS credentials work**

Run: `aws sts get-caller-identity`
Expected: JSON with your account id. (If it errors, the STS token has expired — refresh credentials.)

- [ ] **Step 2: Apply only the ECR module** (gated — confirm before running)

Run: `cd infra && terraform init && terraform apply -target=module.ecr`
Expected: creates 2 ECR repositories. Type `yes` to confirm.

- [ ] **Step 3: Capture repo URLs and registry**

```bash
cd infra
export FRONTEND_REPO=$(terraform output -raw frontend_repo_url)
export BACKEND_REPO=$(terraform output -raw backend_repo_url)
export REGISTRY=$(echo "$FRONTEND_REPO" | cut -d/ -f1)
cd ..
echo "$REGISTRY"
```

- [ ] **Step 4: Docker login to ECR**

Run: `aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin "$REGISTRY"`
Expected: `Login Succeeded`

- [ ] **Step 5: Build and push both images** (Dockerfiles build from repo root context)

```bash
docker build -f backend/Dockerfile  -t "$BACKEND_REPO:latest" .
docker build -f frontend/Dockerfile -t "$FRONTEND_REPO:latest" .
docker push "$BACKEND_REPO:latest"
docker push "$FRONTEND_REPO:latest"
```
Expected: both pushes complete with a digest.

---

## Task 9: Full apply and smoke test (gated)

- [ ] **Step 1: Plan the full stack**

Run: `cd infra && terraform plan`
Expected: a plan creating VPC, subnets, endpoints, ALB, RDS, ECS resources (~40+ resources). Review it.

- [ ] **Step 2: Apply** (gated — confirm before running; RDS Multi-AZ takes ~10-15 min)

Run: `terraform apply`
Expected: completes; outputs `alb_dns_name`, `rds_endpoint`, etc.

- [ ] **Step 3: Wait for services to stabilize**

Run: `aws ecs wait services-stable --cluster $(terraform output -raw ecs_cluster) --services conduit-frontend conduit-backend --region us-west-2`
Expected: returns when both services reach steady state (a few minutes).

- [ ] **Step 4: Seed the database (one-off ECS task)**

```bash
CLUSTER=$(terraform output -raw ecs_cluster)
# Reuse the backend task def + network; override the command to run the seeder.
aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE \
  --task-definition conduit-backend --region us-west-2 \
  --network-configuration "awsvpcConfiguration={subnets=[$(terraform output -json | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["app_subnet_ids"]["value"]))' 2>/dev/null || echo '')],securityGroups=[],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"backend","command":["npm","run","sqlz","--","db:seed:all"]}]}'
```
Expected: a task starts. (Note: `sequelize.sync({alter:true})` already created the schema on backend boot, so seeding is optional demo data. If the override networking is fiddly, seeding can be skipped — the app works empty.)

- [ ] **Step 5: Smoke test the API**

Run: `curl -s "http://$(terraform output -raw alb_dns_name)/api/tags"`
Expected: JSON `{"tags":[...]}` (HTTP 200).

- [ ] **Step 6: Smoke test the SPA**

Run: `curl -sI "http://$(terraform output -raw alb_dns_name)/"`
Expected: `HTTP/1.1 200 OK`, `content-type: text/html`.

- [ ] **Step 7: Record the live URL** in the report (Task 10).

---

## Task 10: Write the graded report

**Files:**
- Create: `docs/aws-report.md`

- [ ] **Step 1: Write `docs/aws-report.md`** following the spec's §10 outline. It MUST cover, with the project's actual values:
  1. Context & objectives (Conduit, RealWorld app, course requirement).
  2. Architecture choice justification — ECS Fargate vs serverless vs EC2 ASG (spec §1 table).
  3. Network design — VPC `10.0.0.0/16`, the 6 subnets across 2 AZs, public/private-app/private-data tiers, routing, **no-NAT + VPC endpoints** trade-off (spec §2).
  4. Application architecture — ALB path routing (`/api/*`→backend, `/*`→frontend), 2 Fargate services, RDS Multi-AZ (spec §3).
  5. Security & least privilege — the SG chain diagram (ALB→tasks→RDS), execution-role vs task-role split, OIDC for CI (spec §4).
  6. Resilience & scalability — multi-AZ everywhere, ECS autoscaling, RDS failover (spec §5).
  7. Observability & CI/CD (spec §6–7).
  8. Cost & teardown (spec §9).
  9. The topology diagram (copy the ASCII diagram from the spec, or render it).
  10. The live ALB URL from Task 9 Step 7 (if applied).

- [ ] **Step 2: Commit**

```bash
git add docs/aws-report.md
git commit -m "docs: add AWS deployment report"
```

---

## Task 11: CI/CD — GitHub Actions deploy workflow (OIDC)

**Files:**
- Create: `.github/workflows/deploy-aws.yml`
- Manual AWS prerequisite (documented, not Terraform): an IAM OIDC identity provider for GitHub + a deploy role trusting this repo, with permissions for ECR push + `ecs:UpdateService` + `iam:PassRole` on the task/execution roles. (Optionally add this as a `modules/cicd` later; for the academic scope a documented manual role is acceptable.)

- [ ] **Step 1: Create `.github/workflows/deploy-aws.yml`**

```yaml
name: Deploy to AWS

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: us-west-2
  CLUSTER: conduit-cluster

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push images
        env:
          REGISTRY: ${{ steps.ecr.outputs.registry }}
        run: |
          docker build -f backend/Dockerfile  -t "$REGISTRY/conduit-backend:${{ github.sha }}"  -t "$REGISTRY/conduit-backend:latest" .
          docker build -f frontend/Dockerfile -t "$REGISTRY/conduit-frontend:${{ github.sha }}" -t "$REGISTRY/conduit-frontend:latest" .
          docker push --all-tags "$REGISTRY/conduit-backend"
          docker push --all-tags "$REGISTRY/conduit-frontend"

      - name: Force new deployments
        run: |
          aws ecs update-service --cluster "$CLUSTER" --service conduit-backend  --force-new-deployment --region "$AWS_REGION"
          aws ecs update-service --cluster "$CLUSTER" --service conduit-frontend --force-new-deployment --region "$AWS_REGION"
```

- [ ] **Step 2: Document the required GitHub secret** `AWS_DEPLOY_ROLE_ARN` and the OIDC role setup in `docs/aws-report.md` §7.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-aws.yml
git commit -m "ci: add AWS ECS deploy workflow (OIDC)"
```

---

## Task 12: Teardown (run after the demo)

- [ ] **Step 1: Destroy all resources** (gated — confirm)

Run: `cd infra && terraform destroy`
Expected: removes ALB, ECS, RDS, VPC, endpoints, ECR (force_delete handles non-empty repos). Type `yes`.

- [ ] **Step 2: Verify nothing lingers**

Run: `aws ecs list-clusters --region us-west-2 && aws rds describe-db-instances --region us-west-2`
Expected: no `conduit-*` resources.

---

## Optional Extensions (note in report, not required)

- **Remote Terraform state:** S3 bucket + DynamoDB lock table; add a `backend "s3"` block to `providers.tf`.
- **HTTPS:** ACM certificate + Route 53 hosted zone + a `:443` listener and an HTTP→HTTPS redirect on the `:80` listener.
- **NAT Gateway per AZ:** only if the app later needs outbound internet.
- **Prometheus/Grafana on ECS:** run the existing monitoring stack as additional Fargate services scraping the backend's `/metrics`.

---

## Self-Review Notes

- **Spec coverage:** VPC/subnets/AZs (Task 2) · no-NAT + VPC endpoints (Task 2) · ECR (Task 3) · RDS Multi-AZ + Secrets (Task 4) · ALB path routing (Task 5) · ECS services + IAM split + autoscaling (Task 6) · least-privilege SG chain (Task 2 SGs + Task 6 roles) · CI/CD OIDC (Task 11) · report (Task 10) · cost/teardown (Task 12). All spec sections mapped.
- **Type consistency:** module output names (`frontend_repo_url`, `backend_repo_url`, `secret_arn`, `*_tg_arn`, `*_subnet_ids`, `*_sg_id`) match their consumers in `main.tf`. Secret JSON keys (`PROD_DB_*`, `JWT_KEY`) match the backend task def `secrets` and the app's `config/config.js` env var names.
- **Known fiddly step:** Task 9 Step 4 (seeder run-task networking). Marked optional — the app boots and works without seed data because `sequelize.sync` builds the schema.
