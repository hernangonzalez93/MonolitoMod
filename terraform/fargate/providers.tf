# Este bloque le dice a Terraform QUÉ "plugin" (provider) necesita para hablar
# con la API de AWS, y qué versión usar. "~> 6.0" significa "cualquier versión
# 6.x, pero no la 7.0" — un rango, no una versión exacta. La versión EXACTA que
# se termina usando queda registrada en el archivo .terraform.lock.hcl, que
# "terraform init" genera automáticamente y SÍ se versiona en Git (a diferencia
# de terraform.tfstate y la carpeta .terraform/, que están en .gitignore desde
# la Fase 0) — es el mismo concepto que un package-lock.json.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Se usa solo para leer el certificado TLS de GitHub y obtener su
    # "thumbprint" (huella digital), necesario para crear el OIDC provider
    # de la Fase 7 — no crea nada en AWS por sí mismo.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Región fija: todo lo que creemos (ECR, ECS, ALB, etc.) vive en us-east-1,
# la misma región que configuramos en "aws configure" en la Fase 5.
provider "aws" {
  region = var.aws_region
}
