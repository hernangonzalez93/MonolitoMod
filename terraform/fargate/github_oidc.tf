# --- OIDC: por qué GitHub Actions puede autenticarse en AWS sin claves ---
#
# Flujo, en 3 pasos:
# 1. GitHub Actions genera un token JWT de corta duración (minutos), firmado
#    por GitHub, que dice "soy una corrida del repo hernangonzalez93/MonolitoMod,
#    rama main".
# 2. AWS valida la firma de ese token contra el "OIDC provider" que registramos
#    acá (que apunta al emisor de tokens de GitHub) — es matemáticamente
#    imposible falsificar ese token sin ser GitHub.
# 3. Si el token es válido Y cumple la condición del rol (repo/rama exactos),
#    AWS entrega credenciales temporales (minutos) para ESE job únicamente.
#
# Nunca existe una AWS access key guardada como secreto de GitHub. Si el
# repo se hiciera público sin querer, o alguien viera los secretos del repo,
# no hay ninguna credencial de larga duración que robar.

# Lee el certificado TLS público de GitHub para obtener el thumbprint que
# AWS exige al registrar el proveedor OIDC. Es un dato público de
# infraestructura de GitHub, no un secreto.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# Quién puede asumir el rol, y bajo qué condición EXACTA.
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restringido a ESTE repo y a la rama "main" específicamente — ni un PR de
    # una rama distinta, ni un fork, ni ningún otro repo de la cuenta pueden
    # asumir este rol. Coincide a propósito con la misma condición que ya
    # usa el job "publish-ghcr" (if: push a main) en ci.yml.
    #
    # Los "*" son necesarios porque el "sub" real que envía GitHub incluye los
    # IDs numéricos e inmutables del usuario/repo pegados con "@" al slug
    # (ej: "repo:hernangonzalez93@54007107/MonolitoMod@1334918361:ref:...") —
    # confirmado leyendo el evento real en CloudTrail tras un primer intento
    # fallido con la condición exacta sin wildcards. Es una protección de
    # GitHub contra reutilización del "sub" si alguien renombra su usuario o
    # el repo más adelante.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repository)[0]}*/${split("/", var.github_repository)[1]}*:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${var.project_name}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

# Permisos de mínimo privilegio: solo lo que el job de deploy necesita hacer,
# nada más. Nada de AdministratorAccess acá — a diferencia del usuario IAM de
# la Fase 5 (para uso manual desde una terminal de confianza), este rol lo
# asume automáticamente un pipeline, así que vale la pena ser estricto.
data "aws_iam_policy_document" "github_actions_deploy_permissions" {
  # ECR: GetAuthorizationToken no admite restricción por recurso (siempre "*"
  # en la documentación de AWS), el resto queda acotado al repo puntual.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  # ECS: solo actualizar/consultar ESTE service puntual, no el cluster entero
  # ni ningun otro servicio que pudiera existir en la cuenta.
  statement {
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [aws_ecs_service.api.id]
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "deploy-permissions"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_deploy_permissions.json
}
