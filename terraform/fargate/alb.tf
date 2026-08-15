# El Load Balancer es el único punto público de entrada. "internal = false"
# significa que tiene una IP/DNS accesible desde internet (no solo desde
# adentro de la VPC).
resource "aws_lb" "api" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

# El "target group" es la lista de destinos a los que el ALB reenvía tráfico.
# type = "ip" (no "instance") porque Fargate no tiene instancias EC2 fijas
# detrás — cada task tiene su propia IP dentro de la VPC, y esa lista la va
# actualizando el propio ECS Service a medida que arrancan/mueren tasks.
resource "aws_lb_target_group" "api" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  # Reusa el mismo endpoint /health que ya usamos en Docker (Fase 1) y en las
  # probes de Kubernetes (Fase 4) — el ALB lo llama periódicamente y solo
  # envía tráfico a las tasks que respondan 200.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# El "listener" conecta el puerto público del ALB (80) con el target group.
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
