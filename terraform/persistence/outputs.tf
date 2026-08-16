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

output "rds_address" {
  description = "Solo el host (sin puerto) — usado por el Lambda para armar la connection string"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "rds_secret_arn" {
  description = "ARN del secreto en Secrets Manager con las credenciales (generado por RDS)"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "sqs_queue_name" {
  value = aws_sqs_queue.purchases.name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.purchases.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.purchases.arn
}

output "sqs_dlq_arn" {
  value = aws_sqs_queue.purchases_dlq.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.purchase_persister.function_name
}
