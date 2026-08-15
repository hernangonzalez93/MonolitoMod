# "data" en vez de "resource": no CREAMOS una VPC nueva, solo LEEMOS la que
# ya existe en la cuenta — toda cuenta de AWS trae una "VPC por defecto" de
# fábrica, con subredes PÚBLICAS (con salida directa a internet) ya creadas
# en cada zona de disponibilidad de la región.
#
# Decisión de esta fase: usar la VPC por defecto en vez de crear una VPC
# propia desde cero con Terraform. Motivo: crear una VPC "a mano" implica
# escribir subredes, tablas de ruteo, Internet Gateway y (si se quisiera una
# subred privada) un NAT Gateway — el NAT Gateway solo, sin usarlo para nada
# más, cuesta ~$32 USD/mes. Para este estudio, usar la VPC por defecto (que
# ya es pública, sin NAT) evita ese costo y nos deja enfocarnos en ECS/Fargate/
# Terraform en vez de en networking desde cero. Es un ejercicio válido para
# más adelante crear una VPC propia (por ejemplo, al llegar a EKS en la Fase 10).
data "aws_vpc" "default" {
  default = true
}

# Todas las subredes que viven dentro de esa VPC por defecto. El Load Balancer
# necesita al menos 2 subredes en zonas de disponibilidad distintas — la VPC
# por defecto ya trae una por cada zona de la región, así que esto normalmente
# devuelve 3 o más.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
