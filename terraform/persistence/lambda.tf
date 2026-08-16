# Empaqueta lo que "dotnet publish" ya generó (paso manual, previo a este
# apply — ver docs/devops/12-lambda.md) en un .zip. Terraform no compila
# código .NET, solo empaqueta binarios ya construidos.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/Lambda/MonolitoMod.Lambda.PurchasePersister/publish"
  output_path = "${path.module}/build/purchase-persister.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-purchase-persister"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Política administrada por AWS: permite crear/borrar las interfaces de red
# (ENIs) que un Lambda dentro de una VPC necesita — sin esto, ni siquiera
# llega a arrancar en modo VPC.
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Política administrada por AWS: logs:CreateLogGroup/CreateLogStream/PutLogEvents.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permisos de mínimo privilegio, escritos a mano: leer/borrar mensajes de
# ESTA cola puntual, y leer ESTE secreto puntual — nada más.
data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.purchases.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "purchase-persister-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# Explícito para poder controlar la retención — si no, Lambda crea el log
# group solo en la primera invocación, pero con retención indefinida.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-purchase-persister"
  retention_in_days = 7
}

resource "aws_lambda_function" "purchase_persister" {
  function_name = "${var.project_name}-purchase-persister"
  role          = aws_iam_role.lambda.arn

  # dotnet10: runtime administrado por AWS, soportado hasta nov. 2028 —
  # verificado contra la documentación oficial antes de usarlo (no todas las
  # versiones de .NET llegan a ser runtime administrado, solo las LTS/STS
  # que AWS decide soportar).
  runtime       = "dotnet10"
  architectures = ["arm64"] # Graviton: mismo criterio de costo que RDS (Fase 10)
  handler       = "MonolitoMod.Lambda.PurchasePersister::MonolitoMod.Lambda.PurchasePersister.Function::FunctionHandler"

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  timeout     = 30
  memory_size = 256

  # Corre dentro de las subredes privadas de la Fase 9, con el Security
  # Group que la Fase 10 ya había creado en anticipación — no hace falta
  # tocar ningún SG en esta fase, el "contrato" de red ya estaba declarado.
  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST       = aws_db_instance.this.address
      DB_PORT       = tostring(aws_db_instance.this.port)
      DB_NAME       = var.db_name
      DB_SECRET_ARN = aws_db_instance.this.master_user_secret[0].secret_arn
    }
  }
}

# Conecta la cola con la función: AWS mismo hace el polling (no corre "dentro"
# de la VPC del Lambda, es infraestructura de AWS aparte) e invoca la función
# con los mensajes recibidos.
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.purchases.arn
  function_name    = aws_lambda_function.purchase_persister.arn
  # batch_size = 1: cada invocación procesa un solo mensaje. Con un batch
  # más grande, una excepción en un solo mensaje reintenta el lote entero
  # (a menos que se implemente "partial batch response", más complejo) — con
  # 1, el radio de la falla queda acotado a ese mensaje puntual.
  batch_size = 1
}
