output "vpc_id" {
  value = aws_vpc.data.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "vpc_endpoints_security_group_id" {
  value = aws_security_group.vpc_endpoints.id
}

output "lambda_security_group_id" {
  description = "SG a usar cuando se despliegue el Lambda en la Fase 12"
  value       = aws_security_group.lambda.id
}

output "rds_endpoint" {
  description = "Host:puerto de la instancia RDS (solo alcanzable desde dentro de la VPC)"
  value       = aws_db_instance.this.endpoint
}

output "rds_secret_arn" {
  description = "ARN del secreto en Secrets Manager con las credenciales (generado por RDS)"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
