# Root module de Terraform SEPARADO de terraform/fargate/ (state propio,
# ".terraform/" y "terraform.tfstate" propios en esta carpeta). No hay
# relación automática entre ambos — si algún día uno necesitara un dato del
# otro (no es el caso hasta ahora), habría que exportarlo explícitamente
# como remote state o pasarlo a mano.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Solo para empaquetar el .zip del Lambda a partir de la carpeta ya
    # publicada con "dotnet publish" (paso manual, ver Fase 12) — no crea
    # nada en AWS por sí mismo.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
