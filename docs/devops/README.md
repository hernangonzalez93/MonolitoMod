# Diario de CI/CD — MonolitoMod

Registro granular de cada fase del plan de estudio de CI/CD, contenedores, Kubernetes y AWS aplicado a este proyecto. Cada fase tiene su propio documento con: qué se hizo, por qué, comandos exactos ejecutados, decisiones tomadas y cómo verificar/reproducir el resultado.

## Índice de fases

| Fase | Tema | Estado |
|---|---|---|
| [00](00-git-github.md) | Git & GitHub | ✅ Completa |
| [01](01-dockerfile.md) | Contenerizar la API (Dockerfile) | ✅ Completa |
| [02](02-ci-security.md) | CI en GitHub Actions + seguridad (Trivy, CodeQL, Dependabot) | ✅ Completa |
| [03](03-cd-ghcr.md) | CD ligero a GitHub Container Registry | ✅ Completa |
| [04](04-k8s-local.md) | Kubernetes local con Docker Desktop | ✅ Completa |
| [05](05-aws-fundamentals.md) | Fundamentos AWS (IAM, Budgets, CLI) | ✅ Completa |
| [06](06-terraform-fargate.md) | Terraform + ECS Fargate | ✅ Completa |
| [07](07-cd-fargate.md) | CD a Fargate desde GitHub Actions | ✅ Completa |
| [08](08-validar-fargate.md) | Validar despliegue en Fargate | ✅ Completa |
| [08b](08b-destroy-fargate.md) | *(addendum)* Destruir y recrear la infra de Fargate | ✅ Completa |
| [09](09-vpc-persistencia.md) | VPC privada para persistencia (RDS + Lambda) | ✅ Completa |
| [10](10-rds-postgres.md) | RDS Postgres | ✅ Completa |
| [11](11-sqs.md) | SQS | ✅ Completa |
| [12](12-lambda.md) | Lambda consumidor de SQS | ✅ Completa |
| [13](13-validar-e2e.md) | Validar el flujo async end-to-end | ✅ Completa |
| 14 | Migrar de Fargate a EKS | ⬜ Pendiente |
| 15 | ArgoCD (GitOps) sobre EKS | ⬜ Pendiente |
| 16 | Autoescalado horizontal (HPA) | ⬜ Pendiente |

> **Nota**: la Fase 9 original (una sola fase de "Postgres directo vía EF Core") se replanteó a pedido explícito del usuario en favor de un pipeline async: API → SQS → Lambda → RDS. El bus en memoria (Inventory/Notifications) no se toca — SQS/Lambda se suman como un tercer consumidor. Detalle de la decisión en 09-vpc-persistencia.md.

## Cómo usar este diario

Cada archivo `NN-nombre-fase.md` sigue la misma estructura:
- **Objetivo**: qué se busca aprender/lograr en la fase.
- **Contexto/decisiones**: por qué se eligió tal enfoque sobre otro.
- **Pasos ejecutados**: comandos reales corridos, en orden, con explicación de cada uno.
- **Archivos creados/modificados**: lista con propósito de cada uno.
- **Verificación**: cómo confirmar que la fase funcionó.
- **Pendientes/notas para la siguiente fase**.
