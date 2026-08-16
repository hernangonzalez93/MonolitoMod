# --- Bastion temporal para validar el pipeline (Fase 13) ---
# No es infraestructura permanente: existe únicamente para poder correr un
# "SELECT" contra la RDS privada desde afuera, algo que quedó pendiente
# desde la Fase 10. Administrado 100% por SSM — sin SSH, sin llave que
# gestionar, sin puerto abierto de entrada (las sesiones de SSM las inicia
# el agente de la instancia hacia AWS, no al revés).

# 3 VPC Endpoints Interface adicionales a los de la Fase 9 (secretsmanager,
# logs): son los que el agente SSM necesita para registrarse y recibir
# comandos sin salida a internet. Se agregan en 1 sola AZ (subred [0]) —
# el bastion es una única instancia, vive en una sola AZ a la vez, no
# necesita la redundancia que sí tiene sentido para RDS.
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.data.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.data.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.data.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# Gateway Endpoint (no Interface): no cobra por hora ni por AZ, es gratis.
# Los repositorios de paquetes de Amazon Linux están servidos desde S3 — sin
# esto, "dnf install postgresql" no tendría cómo descargar nada.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.data.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.project_name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json
}

# Política administrada por AWS: todo lo que el agente SSM necesita para
# registrarse y ejecutar comandos — el caso estándar para el que existe,
# igual que hicimos con las políticas de ECS/Lambda en fases anteriores.
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Mismo criterio de minimo privilegio que el Lambda (Fase 12): el bastion
# necesita leer ESTE secreto puntual para poder correr psql, nada mas.
data "aws_iam_policy_document" "bastion_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "bastion" {
  name   = "read-rds-secret"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_permissions.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "SG del bastion temporal de validacion (Fase 13)"
  vpc_id      = aws_vpc.data.id
  # Sin ingress: SSM no lo necesita (las sesiones las inicia la instancia).
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_vpce" {
  security_group_id            = aws_security_group.bastion.id
  description                  = "HTTPS hacia los VPC Endpoints (SSM, Secrets Manager, etc.)"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
}

# El Gateway Endpoint de S3 (arriba) NO tiene Security Group propio — a
# diferencia de los Interface Endpoints, enruta por IP (vía una "prefix
# list" administrada por AWS), no por SG. Sin esta regla, el egress a S3
# queda bloqueado por el SG del bastion aunque la ruta exista — se
# descubrió en la práctica: "dnf install" colgado con timeout, no un
# error inmediato, porque a nivel de red la ruta SÍ estaba, pero el SG
# tiraba el tráfico silenciosamente.
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_s3" {
  security_group_id = aws_security_group.bastion.id
  description       = "HTTPS hacia S3 (Gateway Endpoint, sin SG propio)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_prefix_list.s3.id
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_rds" {
  security_group_id            = aws_security_group.bastion.id
  description                  = "Postgres hacia RDS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}

# El SG de RDS ya existía (Fase 10) con una sola regla de entrada, desde el
# Lambda. Se agrega esta como recurso aparte, sin tocar la regla original —
# el bastion se suma como un segundo origen autorizado, nada más.
resource "aws_vpc_security_group_ingress_rule" "rds_from_bastion" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres, tambien desde el bastion (Fase 13, temporal)"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion.id
}

# AMI oficial de Amazon, resuelta dinámicamente en vez de hardcodear un ID
# (los AMI ID cambian por región y quedan desactualizados) — ya trae el
# agente de SSM preinstalado.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "bastion" {
  ami = data.aws_ssm_parameter.al2023_arm64.value
  # t4g.nano no es elegible para Free Tier en esta cuenta (verificado con
  # "aws ec2 describe-instance-types --filters Name=free-tier-eligible,..."
  # tras un primer intento fallido) - t4g.micro si lo es, y sigue siendo
  # Graviton/ARM, de sobra para correr psql.
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  # Sin IP publica: no hace falta y no habria ruta de todos modos (subred sin IGW).
  associate_public_ip_address = false

  tags = {
    Name = "${var.project_name}-bastion"
  }
}
