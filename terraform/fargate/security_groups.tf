# Un Security Group es un firewall a nivel de recurso: define qué tráfico
# puede ENTRAR (ingress) y SALIR (egress). Se usan DOS grupos encadenados,
# no uno solo, siguiendo el principio de menor privilegio:
#
#   Internet ──(80, público)──> [SG del ALB] ──(8080, SOLO desde el ALB)──> [SG de ECS]
#
# Así, nadie puede pegarle directo al puerto 8080 de las tasks de Fargate
# desde internet — tienen que pasar obligatoriamente por el Load Balancer.

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Permite HTTP publico hacia el Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Todo el trafico saliente permitido (necesario para reenviar al target group)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-sg"
  description = "Permite trafico al contenedor SOLO desde el Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Puerto del contenedor, solo desde el SG del ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Todo el trafico saliente permitido (necesario para: pull de imagen desde ECR, logs a CloudWatch)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
