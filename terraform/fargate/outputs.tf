# Los "outputs" son valores que Terraform imprime al final de un "apply", y
# que también se pueden consultar después con "terraform output". Sirven para
# no tener que ir a buscar a mano en la consola de AWS cosas como la URL
# pública del Load Balancer o el nombre del repo de ECR.

output "alb_dns_name" {
  description = "URL publica para probar la API (http://<esto>/health)"
  value       = aws_lb.api.dns_name
}

output "ecr_repository_url" {
  description = "URL del repo de ECR, para docker tag / docker push"
  value       = aws_ecr_repository.api.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.api.name
}
