# VPC nueva y separada de la que usa Fargate/ALB (esa sigue siendo la VPC
# por defecto de la cuenta, sin tocar). Esta es exclusiva para RDS + Lambda.
#
# enable_dns_support/enable_dns_hostnames = true es OBLIGATORIO para que los
# VPC Endpoints de más abajo funcionen con DNS privado (private_dns_enabled):
# sin esto, el SDK de AWS dentro del Lambda seguiría resolviendo
# "secretsmanager.us-east-1.amazonaws.com" a una IP pública en vez de a la
# IP privada del endpoint, y el tráfico intentaría salir a internet (donde
# no hay ruta, porque esta VPC no tiene Internet Gateway) y fallaría.
resource "aws_vpc" "data" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# 2 subredes privadas, una por AZ. Deliberadamente NO hay:
# - Internet Gateway (nadie necesita salir a internet desde acá)
# - NAT Gateway (por eso, y porque los VPC Endpoints cubren lo que sí hace falta)
# - map_public_ip_on_launch (default false: correcto, nada acá debe tener IP pública)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.data.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index}"
  }
}

# Tabla de rutas SIN ninguna ruta explícita agregada (ni 0.0.0.0/0 a un IGW,
# ni a un NAT) — solo queda la ruta "local" implícita que AWS agrega sola
# para que las subredes de la VPC se hablen entre sí. Esto es, literalmente
# en código, la garantía de que esta subred no tiene salida a internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.data.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Group de los VPC Endpoints: quién puede llamarlos. Se permite
# HTTPS (443, el único puerto que usan las APIs de AWS) desde cualquier IP
# DENTRO de esta VPC — no hay nada afuera que pueda llegar a esta VPC de
# entrada, así que no hace falta acotarlo más todavía. Se puede ajustar en
# la Fase 12 para restringirlo puntualmente al SG del Lambda.
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpce-sg"
  description = "Permite HTTPS hacia los VPC Endpoints desde dentro de la VPC de datos"
  vpc_id      = aws_vpc.data.id

  ingress {
    description = "HTTPS desde la VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Interface Endpoint hacia Secrets Manager: el Lambda (Fase 12) va a leer acá
# las credenciales de RDS, sin que ese tráfico salga nunca a internet.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.data.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-vpce-secretsmanager"
  }
}

# Interface Endpoint hacia CloudWatch Logs: TODO Lambda necesita esto para
# poder emitir logs, incluso si no llamara a ninguna otra API de AWS.
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.data.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-vpce-logs"
  }
}
