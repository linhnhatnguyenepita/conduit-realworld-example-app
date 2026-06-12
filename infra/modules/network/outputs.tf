output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "app_subnet_ids" { value = aws_subnet.app[*].id }
output "data_subnet_ids" { value = aws_subnet.data[*].id }
output "alb_sg_id" { value = aws_security_group.alb.id }
output "tasks_sg_id" { value = aws_security_group.tasks.id }
output "rds_sg_id" { value = aws_security_group.rds.id }
