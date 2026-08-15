# Fase 6 — Terraform + ECS Fargate

## Objetivo

Primer despliegue real en AWS: provisionar toda la infraestructura con Terraform (no clicks manuales en la consola) y correr la API en ECS Fargate detrás de un Application Load Balancer público. Primera fase donde "funciona" significa "responde desde internet de verdad", no un túnel local.

## Conceptos básicos (el usuario no tenía experiencia previa con Terraform)

- **Terraform** es una herramienta de Infraestructura como Código: se describe el estado deseado en archivos `.tf`, y Terraform calcula y ejecuta los cambios necesarios contra la API de AWS.
- **`terraform init`**: descarga el provider (plugin que sabe hablar con AWS) y genera `.terraform.lock.hcl` (versión exacta resuelta — SÍ se versiona en git, a diferencia de `.terraform/` y `*.tfstate*`, ya excluidos desde la Fase 0).
- **`terraform plan`**: preview de qué se va a crear/cambiar/destruir, sin tocar nada todavía.
- **`terraform apply`**: ejecuta esos cambios de verdad.
- **`terraform.tfstate`**: la "memoria" de Terraform sobre qué existe — necesario para que sepa qué modificar en el próximo `apply` en vez de recrear todo.

Ver también el diagrama de arquitectura mostrado en el chat durante esta fase (Internet → ALB público puerto 80 → ECS Fargate Service puerto 8080 → pull desde ECR / logs a CloudWatch).

## Contexto/decisiones

### VPC por defecto, no una VPC propia

Se usó la VPC por defecto de la cuenta (con `data "aws_vpc" "default"`) en vez de crear una desde cero. Motivo explícito: una VPC propia con subred privada requeriría un NAT Gateway, que cuesta ~$32 USD/mes **solo por existir**, sin usarlo para nada más. La VPC por defecto ya trae subredes públicas (con salida directa a internet vía Internet Gateway) en cada zona de disponibilidad — exactamente lo que hace falta para correr Fargate con IP pública sin NAT. Crear una VPC propia queda como ejercicio pendiente natural para la Fase 10 (EKS).

### Dos Security Groups encadenados, no uno solo

`alb` (80 público) → `ecs_tasks` (8080 solo desde el SG del ALB). Nadie puede pegarle directo al contenedor sin pasar por el Load Balancer — principio de menor privilegio aplicado a nivel de red.

### Solo "execution role", sin "task role" todavía

El execution role es el permiso que usa el *agente* de ECS (para hacer pull de ECR y escribir logs) — no el que usaría la aplicación en sí. Como la app todavía no llama a ninguna API de AWS (eso llega en la Fase 9, con Secrets Manager para la connection string de Postgres), no hace falta un task role por ahora.

### Push manual de la imagen — a propósito, para esta fase

El repo de ECR se crea vacío. Recién en la Fase 7 se automatiza el build+push vía GitHub Actions (mismo patrón que GHCR en la Fase 3). Para poder validar la infraestructura de punta a punta *ahora* en vez de esperar a la Fase 7, se hizo un push manual único de la imagen ya construida en la Fase 1/4 (`monolitomod-api:local`).

### Costo real — y decisión explícita del usuario de no auto-destruir

Antes de aplicar se calculó el costo aproximado: ALB (~$16/mes si queda prendido todo el mes) + Fargate task 0.25vCPU/0.5GB (~$9/mes) — superaría el budget de $5/mes de la Fase 5 en menos de una semana si se deja corriendo sin parar. El usuario decidió explícitamente: **aplicar igual, y no destruir nada salvo que lo pida explícitamente** — el ajuste de presupuesto queda para más adelante. Se documenta la decisión, no se actúa por cuenta propia en sentido contrario.

## Incidentes reales durante esta fase

### 1. `docker login --password-stdin` fallaba con 400 Bad Request vía pipeline de PowerShell

```powershell
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $registry
# Error response from daemon: login attempt to https://.../v2/ failed with status: 400 Bad Request
```
El token en sí era válido (se verificó por separado: JWT de 1772 caracteres, con forma correcta). El problema es específico de cómo PowerShell canaliza texto largo a través de un pipeline hacia el stdin de un proceso nativo — probablemente una diferencia de codificación que corrompe el token en el camino. **Solución**: ejecutar el mismo pipe dentro de `cmd /c "..."` en vez del pipeline nativo de PowerShell, que trata el flujo como texto plano sin la capa extra de PowerShell:
```powershell
cmd /c "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 148142121824.dkr.ecr.us-east-1.amazonaws.com"
# Login Succeeded
```

### 2. Primer `docker push` falló en el último paso (manifest) por timeout de proxy

```
Put "https://.../v2/monolitomod-api/manifests/latest": proxyconnect tcp: dial tcp 192.168.65.1:3128: i/o timeout
```
Las 8 capas de la imagen se subieron bien (`Pushed`); solo el paso final (subir el manifest) chocó con un timeout puntual contra el proxy interno de Docker Desktop (`192.168.65.1:3128`, la IP del gateway de la VM de Docker Desktop). Fue transitorio: un segundo `docker push` completó en segundos (todas las capas ya existían, `Layer already exists`, y el manifest se subió sin problema).

## Pasos ejecutados

```bash
# Terraform
cd terraform/fargate
terraform init          # descarga provider hashicorp/aws ~> 6.0 (resolvió 6.60.0)
terraform fmt            # normaliza formato
terraform validate       # valida sintaxis, sin tocar AWS
terraform plan -out tfplan.out    # preview: 13 to add, 0 to change, 0 to destroy
terraform apply "tfplan.out"      # crea los 13 recursos (ALB tardó ~3m13s)

# Outputs relevantes
# alb_dns_name       = monolitomod-alb-370088204.us-east-1.elb.amazonaws.com
# ecr_repository_url = 148142121824.dkr.ecr.us-east-1.amazonaws.com/monolitomod-api

# Push manual de la imagen (ver incidentes arriba)
cmd /c "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 148142121824.dkr.ecr.us-east-1.amazonaws.com"
docker tag monolitomod-api:local 148142121824.dkr.ecr.us-east-1.amazonaws.com/monolitomod-api:latest
docker push 148142121824.dkr.ecr.us-east-1.amazonaws.com/monolitomod-api:latest   # 2do intento OK

# El servicio ya tenía una task en estado failing (sin imagen); forzar que reintente
aws ecs update-service --cluster monolitomod --service monolitomod-api --force-new-deployment

# Verificación
aws ecs describe-services --cluster monolitomod --services monolitomod-api \
  --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}"
# desired=1, running=1, pending=0

aws elbv2 describe-target-health --target-group-arn <arn> --query "TargetHealthDescriptions[0].TargetHealth"
# {"State": "healthy"}

# Validación real desde internet (sin túneles)
curl -s http://monolitomod-alb-370088204.us-east-1.elb.amazonaws.com/health
# {"status":"healthy"}
curl -s -X POST http://monolitomod-alb-370088204.us-east-1.elb.amazonaws.com/api/purchases -i ...
# 202 Accepted
```

## Archivos creados/modificados

- `terraform/fargate/providers.tf`, `variables.tf`, `data.tf`, `security_groups.tf`, `ecr.tf`, `iam.tf`, `alb.tf`, `ecs.tf`, `outputs.tf`
- `.terraform.lock.hcl` (versionado a propósito, ver arriba)

## Resultado final de esta fase

- 13 recursos de AWS provisionados y funcionando: ECR, ECS cluster/service/task definition, ALB + target group + listener, 2 security groups, IAM role, log group.
- API respondiendo en `http://monolitomod-alb-370088204.us-east-1.elb.amazonaws.com` — validado con `/health` y el flujo completo de compra, desde internet real.
- **Todo queda corriendo** (decisión explícita del usuario) — no se ejecutó `terraform destroy`.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 7**: reemplazar el push manual por un job de GitHub Actions (build → push a ECR → `aws ecs update-service --force-new-deployment`), mismo patrón que GHCR en la Fase 3.
- [ ] El bug de `docker login --password-stdin` vía PowerShell nativo (usar `cmd /c` como workaround) es específico de esta terminal local — en GitHub Actions (Linux) no debería reproducirse.
- [ ] Presupuesto: seguirá corriendo excediendo el budget de $5/mes de la Fase 5 mientras no se ajuste o se destruya explícitamente — es una decisión activa del usuario, no un olvido.
