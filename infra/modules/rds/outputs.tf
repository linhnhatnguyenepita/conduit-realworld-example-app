output "endpoint" { value = aws_db_instance.this.address }
output "secret_arn" { value = aws_secretsmanager_secret.app.arn }
