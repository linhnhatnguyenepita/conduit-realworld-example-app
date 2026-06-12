output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
output "frontend_repo_url" { value = aws_ecr_repository.this["frontend"].repository_url }
output "backend_repo_url" { value = aws_ecr_repository.this["backend"].repository_url }
