# Las "variables" son los parámetros configurables de este código de Terraform.
# Todas tienen un "default", así que se puede correr "terraform apply" sin
# pasar nada — pero quedan documentadas acá en vez de quemadas (hardcoded)
# adentro de cada recurso, por si algún día se quiere reusar este mismo código
# para otro proyecto o entorno.

variable "aws_region" {
  description = "Región de AWS donde se crea todo"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo usado para nombrar todos los recursos (cluster, servicio, imagen, etc.)"
  type        = string
  default     = "monolitomod"
}

variable "container_port" {
  description = "Puerto en el que escucha la API dentro del contenedor (ver Dockerfile: ASPNETCORE_HTTP_PORTS=8080)"
  type        = number
  default     = 8080
}

# 256 (.25 vCPU) / 512 MB: el tamaño más chico que permite Fargate. De sobra
# para esta API de ejemplo, y minimiza el costo por hora mientras esté corriendo.
variable "fargate_cpu" {
  description = "CPU de la task de Fargate, en unidades de CPU de AWS (1024 = 1 vCPU)"
  type        = string
  default     = "256"
}

variable "fargate_memory" {
  description = "Memoria de la task de Fargate, en MB"
  type        = string
  default     = "512"
}

variable "github_repository" {
  description = "Repo de GitHub (owner/nombre) autorizado a asumir el rol de deploy via OIDC"
  type        = string
  default     = "hernangonzalez93/MonolitoMod"
}

# Este módulo (terraform/fargate/) y terraform/persistence/ tienen states
# separados (ver Fase 9) — no hay forma automática de que uno sepa qué creó
# el otro. En vez de usar "terraform_remote_state" (otro concepto a
# introducir), se resuelve con un data source que busca la cola POR NOMBRE
# en la Fase 11 — el nombre es predecible porque lo controlamos nosotros en
# ambos lados (acá, y en terraform/persistence/variables.tf: project_name +
# "-purchases").
variable "sqs_queue_name" {
  description = "Nombre de la cola SQS (creada en terraform/persistence/) a la que la API publica"
  type        = string
  default     = "monolitomod-data-purchases"
}
