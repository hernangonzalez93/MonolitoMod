variable "aws_region" {
  description = "Región de AWS donde se crea todo"
  type        = string
  default     = "us-east-1"
}

# Prefijo distinto al de terraform/fargate/ ("monolitomod") a propósito: dos
# preocupaciones separadas, nombres separados, fácil de distinguir en la
# consola de AWS qué recurso pertenece a qué parte del sistema.
variable "project_name" {
  description = "Prefijo para nombrar los recursos de esta capa (VPC, RDS, SQS, Lambda)"
  type        = string
  default     = "monolitomod-data"
}

variable "vpc_cidr" {
  description = "Rango de IPs de la VPC privada de persistencia"
  type        = string
  default     = "10.0.0.0/16"
}

# 2 subredes /24 (256 IPs cada una, de sobra para RDS + Lambda) en 2 AZs
# distintas — RDS exige un DB Subnet Group con al menos 2 AZs aunque la
# instancia final sea single-AZ (Fase 10).
variable "private_subnet_cidrs" {
  description = "CIDRs de las 2 subredes privadas (una por AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

# db.t4g.micro (Graviton/ARM): la clase mas chica y barata disponible para
# Postgres en RDS. Verificado que esta disponible para la version elegida
# con "aws rds describe-orderable-db-instance-options" antes de escribir esto.
variable "db_instance_class" {
  description = "Clase de instancia de RDS"
  type        = string
  default     = "db.t4g.micro"
}

# Solo el major version: deja que AWS elija/actualice el minor automaticamente
# (mismo criterio que usamos con "~> 6.0" para providers o "v6" para Actions).
# Verificado que "18" es la ultima major disponible con
# "aws rds describe-db-engine-versions" antes de escribir esto.
variable "db_engine_version" {
  description = "Version mayor de Postgres"
  type        = string
  default     = "18"
}

# Nombre de la base de datos en si (no del recurso) — Postgres no permite
# guiones en este campo, por eso no reusa "project_name" tal cual.
variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "monolitomod"
}

variable "db_username" {
  description = "Usuario administrador de la base"
  type        = string
  default     = "monolitomod_admin"
}
