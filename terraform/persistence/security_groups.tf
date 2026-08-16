# Los grupos se declaran "vacíos" (sin ingress/egress inline) a propósito:
# lambda necesita apuntar al SG de rds, y rds necesita apuntar al SG de
# lambda — si esas reglas fueran bloques inline dentro de cada resource,
# Terraform vería una dependencia circular real (para crear A necesita el ID
# de B, y para crear B necesita el ID de A) y fallaría con "Cycle". La forma
# de resolverlo es crear ambos SGs primero (vacíos), y las reglas que se
# referencian entre sí como recursos aparte — así ya existen los dos IDs
# antes de que se intente crear cualquier regla.

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "SG del Lambda que consume SQS y escribe en RDS (Fase 12)"
  vpc_id      = aws_vpc.data.id
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite Postgres SOLO desde el SG del Lambda"
  vpc_id      = aws_vpc.data.id
}

# --- Reglas del SG de lambda (salida) ---

resource "aws_vpc_security_group_egress_rule" "lambda_to_rds" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Postgres hacia RDS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_vpce" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "HTTPS hacia los VPC Endpoints"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
}

# --- Regla del SG de rds (entrada) ---

resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres, solo desde el Lambda"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

# RDS no inicia conexiones salientes en el uso normal — no hace falta
# ninguna regla de egress para su SG.
