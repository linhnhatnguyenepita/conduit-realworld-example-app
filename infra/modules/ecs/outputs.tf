output "cluster_name" { value = aws_ecs_cluster.this.name }
output "frontend_service" { value = aws_ecs_service.frontend.name }
output "backend_service" { value = aws_ecs_service.backend.name }
