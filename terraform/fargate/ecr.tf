# El registry de imágenes en AWS (equivalente a lo que es ghcr.io en la Fase 3,
# pero dentro de la cuenta de AWS — Fargate necesita poder ver la imagen desde
# adentro de AWS, y no puede autenticarse contra un GHCR privado sin trabajo
# extra, así que para ECS el destino natural es ECR).
resource "aws_ecr_repository" "api" {
  name                 = "${var.project_name}-api"
  image_tag_mutability = "MUTABLE" # permite reusar el tag "latest" en cada push, igual que hicimos con GHCR

  image_scanning_configuration {
    scan_on_push = true # ECR escanea vulnerabilidades automáticamente al recibir una imagen nueva (complementa al Trivy de la Fase 2)
  }
}

# Sin esto, ECR acumularía indefinidamente cada imagen que se suba (cada push
# de la Fase 7 en adelante) y generaría costo de almacenamiento innecesario.
# Se queda solo con las últimas 10 imágenes.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantener solo las ultimas 10 imagenes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
