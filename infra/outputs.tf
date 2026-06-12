output "alb_dns_name" { value = module.alb.dns_name }
output "frontend_repo_url" { value = module.ecr.frontend_repo_url }
output "backend_repo_url" { value = module.ecr.backend_repo_url }
output "rds_endpoint" { value = module.rds.endpoint }
output "ecs_cluster" { value = module.ecs.cluster_name }
