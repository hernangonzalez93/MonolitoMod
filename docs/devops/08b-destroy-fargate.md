# Addendum — Destrucción de la infraestructura de Fargate

No es una fase numerada del plan de estudio: es un ejercicio pedido explícitamente después de la Fase 8, para aprender el ciclo completo "crear → usar → destruir → recrear" con Terraform, y validar en la práctica la advertencia sobre `force_delete` que quedó anotada desde la Fase 6.

## Paso 1 — `force_delete = true` en el repo de ECR

Antes de poder destruir todo de forma limpia, hubo que resolver el problema ya anticipado: `aws_ecr_repository` no permite borrarse si tiene imágenes adentro, salvo que se fuerce.

```hcl
resource "aws_ecr_repository" "api" {
  # ...
  force_delete = true
}
```

Se aplicó como un cambio aislado primero (`terraform plan` → `apply`, 1 recurso modificado, sin costo ni impacto — un update in-place de un atributo de ECR), **antes** de intentar el destroy. Confirmado que la anticipación de la Fase 6 era correcta: sin este cambio, el `destroy` habría fallado a mitad de camino.

## Paso 2 — Preview del destroy

```bash
terraform plan -destroy -out tfplan-destroy.out
```
`Plan: 0 to add, 0 to change, 16 to destroy` — los 16 recursos acumulados entre la Fase 6 (13) y la Fase 7 (3: OIDC provider, rol, policy).

## Paso 3 — Ejecutar

```bash
terraform apply "tfplan-destroy.out"
```

**Dato real para tener en cuenta a futuro**: el `aws_ecs_service` tardó **7m4s** en destruirse — mucho más que el resto. Motivo: el `aws_lb_target_group` tiene `deregistration_delay = 300` (5 minutos), el valor por defecto de AWS que nunca se sobreescribió explícitamente en `alb.tf`. ECS espera ese drenaje completo de conexiones antes de dar por terminada la baja del servicio. Si se quisiera un destroy más rápido en un ciclo de estudio con creaciones/destrucciones frecuentes, se podría bajar ese valor (por ejemplo a 30s) a costa de cortar conexiones en curso de forma más abrupta en un entorno real.

`Apply complete! Resources: 0 added, 0 changed, 16 destroyed.`

## Verificación

```bash
aws ecs list-clusters --query "clusterArns"            # []
aws ecr describe-repositories                            # vacío
aws elbv2 describe-load-balancers                         # vacío
terraform state list                                      # vacío
```

Costo de esta infraestructura a partir de este punto: **$0**.

## Para recrear todo

```bash
cd terraform/fargate
terraform apply
```

Recrea los 16 recursos. Cosas que **van a cambiar** respecto a como estaban:
- El ALB va a tener un **DNS público nuevo** (sufijo aleatorio distinto a `monolitomod-alb-370088204...`).
- El repo de ECR se recrea vacío — hace falta un primer push (manual, como en la Fase 6, o dejar que lo resuelva el próximo merge a `main` vía el job `deploy-fargate` de la Fase 7).
- El rol de OIDC para GitHub Actions se recrea con el mismo nombre y el mismo trust policy (ya con el fix del wildcard incluido) — no debería hacer falta tocar las variables de repo en GitHub, sus valores (nombres, región) no cambian.

## Archivos modificados

- `terraform/fargate/ecr.tf` — `force_delete = true` agregado de forma permanente (si se recrea el repo más adelante, ya no va a repetirse este problema).
