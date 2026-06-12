# Identity of whoever's AWS credentials are active. Used to auto-derive the
# LabRole ARN so the teacher only needs valid credentials — no manual config.
data "aws_caller_identity" "current" {}

# Auto-generated JWT signing key, used only when var.jwt_key is left empty.
resource "random_password" "jwt" {
  length  = 48
  special = false
}

locals {
  # AWS Academy accounts deny iam:CreateRole, so dedicated ECS roles cannot be
  # created. With use_lab_role = true (default), reuse the account's pre-existing
  # LabRole, auto-derived from the caller's account ID. An explicit lab_role_arn
  # overrides the derivation; use_lab_role = false makes Terraform create the
  # least-privilege roles instead (only possible in an unrestricted account).
  lab_role_arn = var.use_lab_role ? (
    var.lab_role_arn != "" ? var.lab_role_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  ) : ""

  jwt_key = var.jwt_key != "" ? var.jwt_key : random_password.jwt.result
}

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
  jwt_key           = local.jwt_key
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
  lab_role_arn    = local.lab_role_arn
}
