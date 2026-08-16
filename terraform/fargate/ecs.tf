# El "cluster" en Fargate no es un grupo de servidores (a diferencia de ECS
# sobre EC2) — es solo un agrupador lógico/nombre bajo el cual viven los
# servicios. AWS administra el cómputo real por detrás, invisible para nosotros.
resource "aws_ecs_cluster" "this" {
  name = var.project_name
}

# Adónde van los logs del contenedor (equivalente a "docker logs", pero
# centralizado). retention_in_days evita que se acumulen para siempre y generen
# costo de almacenamiento innecesario.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project_name}-api"
  retention_in_days = 7
}

# La "task definition" es el plano/receta de cómo correr el contenedor: qué
# imagen, cuánta CPU/memoria, qué puerto, a dónde van los logs. NO es el
# contenedor corriendo en sí — es la plantilla que el "service" (más abajo)
# usa para lanzar tasks reales.
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-api"
  requires_compatibilities = ["FARGATE"]
  # "awsvpc": cada task recibe su propia interfaz de red con IP propia dentro
  # de la VPC (a diferencia del modo "bridge", heredado de Docker clásico).
  # Es el único modo de red que soporta Fargate.
  network_mode       = "awsvpc"
  cpu                = var.fargate_cpu
  memory             = var.fargate_memory
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  # task_role_arn (Fase 11): el permiso que usa la APLICACIÓN (sqs:SendMessage),
  # distinto del execution_role_arn de arriba (que usa el agente de ECS).
  task_role_arn = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name = "${var.project_name}-api"
      # :latest -> el mismo tag que se sube manualmente en esta fase, y que la
      # Fase 7 va a automatizar vía GitHub Actions (mismo patrón que GHCR en la Fase 3).
      image = "${aws_ecr_repository.api.repository_url}:latest"
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      # SQS_QUEUE_URL: la API la lee en runtime (Program.cs) para saber a
      # dónde publicar. Se resuelve automáticamente vía el data source de
      # iam.tf — no está hardcodeada acá.
      # AWS_REGION: explícito a propósito, para no depender de si Fargate lo
      # setea solo — el SDK de AWS para .NET sí lo resuelve automáticamente
      # si la variable existe, pero no está garantizado que ECS la agregue
      # por su cuenta (a diferencia de Lambda, donde sí es automático).
      environment = [
        {
          name  = "SQS_QUEUE_URL"
          value = data.aws_sqs_queue.purchases.url
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# El "service" es lo que mantiene la task definition corriendo: si una task
# se cae, el service lanza otra para volver a desired_count. También es quien
# registra/desregistra tasks en el target group del ALB a medida que aparecen
# o desaparecen.
resource "aws_ecs_service" "api" {
  name            = "${var.project_name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets = data.aws_subnets.default.ids
    # Sin NAT Gateway (ver data.tf), la única forma de que la task llegue a
    # internet -y por lo tanto a ECR/CloudWatch- es que tenga su propia IP
    # pública, ya que está en una subred pública.
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "${var.project_name}-api"
    container_port   = var.container_port
  }

  # El service depende del listener (no solo del target group) porque el ALB
  # necesita estar realmente escuchando antes de que tenga sentido registrar
  # tasks contra su target group.
  depends_on = [aws_lb_listener.api]
}
