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

# JWT signing key for the backend. Leave empty to auto-generate one (recommended
# for the academy: no secret to manage). Set explicitly to keep a stable key.
variable "jwt_key" {
  type      = string
  sensitive = true
  default   = ""
}

# true (default): reuse the account's pre-existing LabRole for the ECS roles —
#   required in AWS Academy accounts, which deny iam:CreateRole. The ARN is
#   auto-derived from the active credentials' account ID (see locals in main.tf).
# false: let Terraform create dedicated least-privilege roles (unrestricted accounts only).
variable "use_lab_role" {
  type    = bool
  default = true
}

# Optional explicit LabRole ARN. Empty = auto-derive arn:aws:iam::<account>:role/LabRole.
variable "lab_role_arn" {
  type    = string
  default = ""
}
