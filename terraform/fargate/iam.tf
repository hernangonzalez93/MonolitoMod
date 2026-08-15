# El "execution role" NO es un permiso para nuestra aplicación — es el permiso
# que usa el AGENTE de ECS (la infraestructura de AWS que arranca el contenedor)
# para poder: descargar la imagen desde ECR, y escribir logs en CloudWatch.
# Sin este rol, la task ni siquiera llega a arrancar el contenedor.
#
# (Si más adelante, en la Fase 9, la aplicación necesitara llamar directamente
# a una API de AWS -por ejemplo leer un secreto de Secrets Manager para la
# connection string de Postgres- hara falta un segundo rol distinto, el "task
# role", que sí usa la aplicación en tiempo de ejecución. No hace falta todavía.)

# "assume_role_policy": quién puede "ponerse" este rol. Acá decimos que
# únicamente el servicio de ECS Tasks puede asumirlo — ninguna otra cosa en
# la cuenta puede usarlo.
data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# Política administrada por AWS con exactamente los permisos que necesita el
# agente de ECS (ecr:GetDownloadUrlForLayer, logs:CreateLogStream, etc.) — no
# hace falta escribirla a mano, es el caso estándar para el que existe.
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
