variable "project" { type = string }
variable "region" { type = string }
variable "app_subnet_ids" { type = list(string) }
variable "tasks_sg_id" { type = string }
variable "frontend_image" { type = string }
variable "backend_image" { type = string }
variable "frontend_tg_arn" { type = string }
variable "backend_tg_arn" { type = string }
variable "secret_arn" { type = string }

# When set (e.g. AWS Academy Learner Lab, where iam:CreateRole is denied), this
# pre-existing role is reused for the ECS execution + task roles instead of
# creating dedicated least-privilege roles. Empty string = create our own roles.
variable "lab_role_arn" {
  type    = string
  default = ""
}
