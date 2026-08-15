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
| 08 | Validar despliegue en Fargate | ⬜ Pendiente |
| 09 | Persistencia con Postgres (RDS) | ⬜ Pendiente |
| 10 | Migrar de Fargate a EKS | ⬜ Pendiente |
| 11 | ArgoCD (GitOps) sobre EKS | ⬜ Pendiente |
| 12 | Autoescalado horizontal (HPA) | ⬜ Pendiente |

## Cómo usar este diario

Cada archivo `NN-nombre-fase.md` sigue la misma estructura:
- **Objetivo**: qué se busca aprender/lograr en la fase.
- **Contexto/decisiones**: por qué se eligió tal enfoque sobre otro.
- **Pasos ejecutados**: comandos reales corridos, en orden, con explicación de cada uno.
- **Archivos creados/modificados**: lista con propósito de cada uno.
- **Verificación**: cómo confirmar que la fase funcionó.
- **Pendientes/notas para la siguiente fase**.
