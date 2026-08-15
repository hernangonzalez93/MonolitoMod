# Fase 7 — CD a Fargate desde GitHub Actions

## Objetivo

Reemplazar el push manual de la Fase 6 por un job automático: cada merge a `main` construye, escanea, publica en ECR y despliega a Fargate sin intervención humana — mismo patrón que GHCR en la Fase 3, pero cruzando hacia una cuenta de AWS distinta.

## Contexto/decisiones

### OIDC en vez de Access Keys — el concepto

En vez de guardar una AWS Access Key + Secret Key como secreto de GitHub (una credencial de larga duración: si se filtra, sirve para siempre hasta que alguien la rote a mano), se configuró **OIDC federation**:

1. GitHub Actions genera un token de identidad de corta duración (JWT, minutos de vida) firmado por GitHub, que dice quién está corriendo (repo, rama).
2. AWS tiene registrado un "OIDC provider" que confía en tokens firmados por GitHub.
3. Un IAM Role específico dice "confío en ese provider, pero solo si el token dice que es *este* repo en la rama *main*" — si el token no cumple exactamente esa condición, AWS rechaza el intercambio.
4. Si todo coincide, AWS entrega credenciales temporales (minutos) válidas solo para ese job puntual.

Ninguna credencial de larga duración existe en ningún lado. Ver `terraform/fargate/github_oidc.tf` para la implementación completa, con comentarios.

### Permisos de mínimo privilegio (a diferencia del usuario IAM de la Fase 5)

El usuario `monolitomod-terraform` de la Fase 5 tiene `AdministratorAccess` (uso manual, desde una terminal de confianza). Este rol, en cambio, lo asume automáticamente un pipeline — se le dieron únicamente los permisos puntuales que el job necesita:
- `ecr:GetAuthorizationToken` (sin restricción de recurso, la propia API de AWS no lo permite)
- Push de capas/imágenes, acotado al ARN exacto del repo `monolitomod-api`
- `ecs:UpdateService` / `ecs:DescribeServices`, acotado al ARN exacto del service `monolitomod-api` — ni siquiera puede tocar otro servicio del mismo cluster si existiera.

### "Build once, promote" también hacia ECR

Igual que con GHCR en la Fase 3: el job `deploy-fargate` no reconstruye la imagen — descarga el mismo artifact que `docker-scan` generó y ya escaneó con Trivy, y lo publica tal cual a ECR. La imagen que corre en Fargate es exactamente la que pasó el gate de seguridad.

### No hace falta una nueva revisión de task definition

La task definition (Fase 6) apunta a `:latest`. Como ECS vuelve a hacer `pull` de la imagen cada vez que arranca una task nueva, `aws ecs update-service --force-new-deployment` alcanza: para las tasks viejas, arranca tasks nuevas, que se traen la imagen recién publicada. No hay que registrar una nueva revisión de la task definition en cada deploy.

### `aws ecs wait services-stable` — no reportar éxito a ciegas

El job espera explícitamente a que ECS confirme que las tasks nuevas están corriendo y pasando el health check del ALB antes de terminar. Si algo sale mal (imagen rota, health check fallando), el job **falla ahí**, en vez de reportar un `git push` exitoso mientras el servicio real está caído.

## Incidente real: el trust policy de OIDC no coincidía (formato de "sub" cambió)

Primer intento de deploy: falló en el paso "Configurar credenciales de AWS via OIDC" con:
```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```
El mensaje no dice *por qué* — así que en vez de adivinar, se consultó **CloudTrail** (que registra el intento real, aunque haya sido denegado):
```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity --max-results 5
```
El evento mostró el `sub` real que GitHub envió:
```
repo:hernangonzalez93@54007107/MonolitoMod@1334918361:ref:refs/heads/main
```
La condición del trust policy esperaba el formato "clásico" documentado (`repo:owner/repo:ref:refs/heads/main`), sin los sufijos `@54007107` y `@1334918361` — que son los **IDs numéricos inmutables** del usuario y del repo, que GitHub empezó a incluir pegados al slug con `@`. Es una protección real: si alguien renombra su usuario o el repo, el string `owner/repo` puede terminar reclamado por otra cuenta más adelante — el ID numérico no cambia nunca, así que GitHub lo incluye para que una condición de confianza no quede huérfana o, peor, la termine heredando otra persona.

**Fix**: condición con wildcards en vez de match exacto:
```hcl
values = ["repo:${split("/", var.github_repository)[0]}*/${split("/", var.github_repository)[1]}*:ref:refs/heads/main"]
# -> "repo:hernangonzalez93*/MonolitoMod*:ref:refs/heads/main"
```
Se aplicó el cambio (`terraform apply`, 1 recurso modificado, sin costo — es un IAM role) y se volvió a correr **solo el job que había fallado** con `gh run rerun --failed`, sin necesidad de un commit nuevo — el fix fue del lado de AWS, no del código versionado del workflow.

## Pasos ejecutados

```bash
# Terraform: OIDC provider + IAM role (ver terraform/fargate/github_oidc.tf)
cd terraform/fargate
terraform init      # nuevo provider hashicorp/tls ~> 4.0 (resolvió 4.3.0)
terraform plan -out tfplan.out    # 3 to add
terraform apply "tfplan.out"

# Variables de repo en GitHub (no secretas: ARNs, nombres, región)
gh variable set AWS_ROLE_ARN --body "arn:aws:iam::148142121824:role/monolitomod-github-actions-deploy"
gh variable set AWS_REGION --body "us-east-1"
gh variable set ECR_REPOSITORY --body "monolitomod-api"
gh variable set ECS_CLUSTER --body "monolitomod"
gh variable set ECS_SERVICE --body "monolitomod-api"

# (edición de .github/workflows/ci.yml: nuevo job deploy-fargate)

# PR, merge a main -> el push real dispara el primer intento de deploy-fargate (FALLA, ver incidente arriba)

# Diagnóstico
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity --max-results 5

# Fix del trust policy + apply
terraform plan -out tfplan.out    # 1 to change
terraform apply "tfplan.out"

# Reintento sin nuevo commit
gh run rerun <run-id> --failed

# Validación real, contra el ALB, con el deploy 100% automatizado
curl -s http://monolitomod-alb-370088204.us-east-1.elb.amazonaws.com/health
curl -s -X POST http://monolitomod-alb-370088204.us-east-1.elb.amazonaws.com/api/purchases -i ...
```

## Archivos creados/modificados

- `terraform/fargate/github_oidc.tf` — OIDC provider, IAM role, policy de mínimo privilegio.
- `terraform/fargate/providers.tf` — provider `hashicorp/tls` agregado.
- `terraform/fargate/variables.tf` — variable `github_repository`.
- `terraform/fargate/outputs.tf` — output `github_actions_role_arn`.
- `.github/workflows/ci.yml` — job `deploy-fargate`.
- Variables de repo en GitHub: `AWS_ROLE_ARN`, `AWS_REGION`, `ECR_REPOSITORY`, `ECS_CLUSTER`, `ECS_SERVICE`.

## Resultado final de esta fase

- Todo push a `main` que pase `build-test` + `docker-scan` despliega automáticamente a Fargate, sin intervención manual y sin credenciales de larga duración en ningún lado.
- Validado con un deploy real de punta a punta: código → CI → ECR → ECS → ALB respondiendo.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 8**: validación más exhaustiva del despliegue (posiblemente disparando un cambio real de código y siguiendo todo el camino).
- [ ] El formato de `sub` con IDs numéricos es bueno tenerlo presente para la Fase 10 (EKS) si en algún momento se usa IRSA (IAM Roles for Service Accounts) u otro mecanismo de OIDC dentro del clúster — mismo tipo de gotcha puede repetirse.
