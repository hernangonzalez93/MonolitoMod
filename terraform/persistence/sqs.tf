# Dead-letter queue: si el Lambda (Fase 12) falla al procesar un mensaje
# repetidamente, en vez de reintentarlo para siempre (o perderlo en silencio),
# SQS lo mueve acá después de "maxReceiveCount" intentos. Se puede inspeccionar
# después para entender qué salió mal, sin que bloquee el resto de la cola.
resource "aws_sqs_queue" "purchases_dlq" {
  name                      = "${var.project_name}-purchases-dlq"
  message_retention_seconds = 1209600 # 14 días (el máximo) — tiempo de sobra para investigar un fallo
  sqs_managed_sse_enabled   = true    # cifrado en reposo, gestionado por AWS, sin costo extra
}

resource "aws_sqs_queue" "purchases" {
  name                      = "${var.project_name}-purchases"
  message_retention_seconds = 345600 # 4 días
  # Cuánto tiempo un mensaje queda "invisible" para otros consumidores después
  # de que alguien lo recibe, mientras lo procesa. Si el Lambda tarda más que
  # esto sin confirmar el mensaje, SQS asume que falló y lo vuelve a ofrecer.
  # 30s es el default de AWS; alcanza de sobra para un insert simple en RDS,
  # se puede ajustar en la Fase 12 si el Lambda necesita más tiempo.
  visibility_timeout_seconds = 30
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.purchases_dlq.arn
    maxReceiveCount     = 3
  })
}
