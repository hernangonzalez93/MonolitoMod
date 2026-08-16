# Fase 13 — Validar el flujo async end-to-end

## Objetivo

Cerrar la pregunta que quedó abierta desde la Fase 10: confirmar con una consulta real (`SELECT`) que el pipeline completo (API → SQS → Lambda → RDS) persiste los datos correctamente — no solo evidencia indirecta (logs del Lambda, cola vaciada) como en las Fases 11/12.

## Contexto/decisiones

### Bastion temporal administrado por SSM, no SSH

Instancia EC2 mínima (`t4g.micro`), sin IP pública, sin llave SSH que gestionar, sin ningún puerto de entrada abierto — las sesiones de SSM las inicia el propio agente de la instancia hacia AWS, nunca al revés. Se agregó como un segundo origen autorizado en el Security Group de RDS (Fase 10), sin tocar la regla que ya existía para el Lambda.

### 3 VPC Endpoints más, en 1 sola AZ (decisión explícita)

`ssm`, `ssmmessages`, `ec2messages` — los que el agente de SSM necesita para registrarse sin salida a internet. A diferencia de los de la Fase 9 (`secretsmanager`, `logs`, en 2 AZs por ser infraestructura permanente), estos se desplegaron en una sola AZ: el bastion es una única instancia temporal, no necesita la redundancia de RDS.

### `SSM Run Command`, no `Session Manager` interactivo

Para esta validación puntual y scripteada, se usó `aws ssm send-command` (ejecuta un comando y devuelve el resultado) en vez de abrir una sesión interactiva de Session Manager con port-forwarding. Mismo mecanismo de acceso, pero más simple de orquestar sin una terminal interactiva persistente.

## Incidentes reales (fueron varios, y todos aportan)

### 1. `t4g.nano` no es elegible para Free Tier en esta cuenta

Primer intento de crear la instancia falló: `InvalidParameterCombination: The specified instance type is not eligible for Free Tier`. Se verificó con `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` en vez de adivinar una alternativa — `t4g.micro` sí es elegible (el `.nano` no), se ajustó el tamaño sin cambiar de familia (sigue siendo Graviton/ARM).

### 2. El Gateway Endpoint de S3 no cubre el endpoint "dualstack"

`dnf install postgresql16` colgaba indefinidamente (timeout, no un error). Diagnóstico paso a paso:
- Los repos de AL2023 apuntan por defecto a `cdn.amazonlinux.com` — confirmado con `curl` desde el bastion que esa URL no es alcanzable desde la VPC privada (timeout real).
- Se leyó la configuración real del repo (`/etc/yum.repos.d/amazonlinux.repo`, no un doc externo) — el `mirrorlist` real usa `al2023-repos-$awsregion-de612dc2.s3$dualstack.$awsregion.$awsdomain`, que sí resuelve a IPs públicas de S3 vía DNS, pero **tampoco** era alcanzable.
- **Causa real**: es una limitación documentada de AWS — los VPC Gateway Endpoints para S3 no cubren el endpoint *dualstack* de S3 (`s3.dualstack.<region>.amazonaws.com`), solo el regional simple (`s3.<region>.amazonaws.com`). Se comprobó sobreescribiendo la variable `dualstack` de dnf a vacío (`/etc/dnf/vars/dualstack`).

### 3. El Gateway Endpoint tampoco tiene Security Group — faltaba una regla de egress

Aun con la URL correcta (sin dualstack), la conexión seguía sin funcionar. A diferencia de los Interface Endpoints (que sí tienen un SG asociado, ya contemplado para el bastion), un **Gateway Endpoint no tiene Security Group propio** — enruta por IP a través de una *prefix list* administrada por AWS, y el SG del bastion no tenía ninguna regla de salida que lo permitiera (solo egress hacia otros SGs puntuales). Se agregó una regla de egress puerto 443 hacia la prefix list de S3 (`data "aws_prefix_list"`, resuelta dinámicamente, no hardcodeada) — recién ahí funcionó `dnf install`.

### 4. PowerShell corrompió el JSON al reencolar un mensaje manualmente

Al rescatar el mensaje que había quedado en la DLQ desde la Fase 12 (reencolarlo a la cola principal con `aws sqs send-message --message-body $body`), el Lambda lo rechazó con `System.Text.Json.JsonException: 'P' is an invalid start of a property name` — el body había perdido **todas** las comillas dobles en el camino (`{PurchaseId:...}` en vez de `{"PurchaseId":...}`). Causa: pasar un string con comillas embebidas como argumento de línea de comandos a un ejecutable nativo (`aws.exe`) desde PowerShell puede mangled las comillas internas de forma impredecible. El mensaje agotó sus 3 reintentos (`maxReceiveCount`) y volvió solo a la DLQ — **segunda confirmación real** del mecanismo de la Fase 11, esta vez sobre un fallo genuino de datos, no de código. Fix: escribir el body a un archivo y usar `--message-body file://...` (mismo patrón ya usado en toda la sesión para evitar exactamente este tipo de problema de escaping).

## Validación real (el objetivo de la fase)

```sql
-- Compra persistida en la Fase 12
SELECT id, customer_email, occurred_on_utc FROM purchases;
--  9852b728-... | fase12-validacion@example.com | 2026-08-16 21:22:41...

-- Compra generada y verificada íntegramente DENTRO de esta fase
SELECT product_id, quantity FROM purchase_items WHERE purchase_id = '7f75ab0b-...';
--  widget-e2e-a | 3
--  widget-e2e-b | 1

-- El mensaje de la Fase 11, rescatado de la DLQ y reprocesado con éxito
SELECT customer_email, product_id, quantity FROM purchases p JOIN purchase_items i ON i.purchase_id = p.id;
-- fase11-validacion@example.com | widget-sqs    | 5
-- fase12-validacion@example.com | widget-lambda | 7
-- fase13-e2e@example.com        | widget-e2e-a  | 3
-- fase13-e2e@example.com        | widget-e2e-b  | 1
```

Las 4 filas de todas las fases anteriores están correctamente persistidas, con las cantidades y emails exactos. Ambas colas (principal y DLQ) quedaron vacías al finalizar.

## Pasos ejecutados

```bash
cd terraform/persistence
# bastion.tf: VPC Endpoints (ssm, ssmmessages, ec2messages, s3), IAM role,
# Security Group, instancia EC2 — ver incidentes arriba para los ajustes
# que hicieron falta sobre la primera versión.
terraform plan -out tfplan.out
terraform apply "tfplan.out"    # 12 recursos, con 2 vueltas mas por los incidentes 1 y 3

# Instalar psql sin acceso a internet (solo Gateway Endpoint de S3)
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters file://install.json   # dnf install -y postgresql16

# Query real
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters file://query.json
aws ssm get-command-invocation --command-id <id> --instance-id <id>

# Compra fresca generada dentro de esta fase
curl -X POST http://<alb>/api/purchases -d '{"customerEmail":"fase13-e2e@example.com",...}'

# Rescate del mensaje de la DLQ (Fase 12)
aws sqs receive-message --queue-url <dlq-url>          # obtener ReceiptHandle
aws sqs send-message --queue-url <main-url> --message-body file://redrive-body.json
aws sqs delete-message --queue-url <dlq-url> --receipt-handle <handle>
```

## Archivos creados/modificados

- `terraform/persistence/bastion.tf` — VPC Endpoints, IAM, Security Groups, instancia EC2.

## Resultado final de esta fase

- Pipeline completo validado con consultas SQL reales, no solo logs indirectos.
- Bastion administrado 100% por SSM, sin SSH, sin IP pública, sin puertos de entrada.
- 4 incidentes reales documentados — cada uno con causa raíz identificada, no solo "se arregló probando".
- Costo de esta fase si queda todo corriendo: ~$22/mes (3 endpoints, 1 AZ) + ~$3/mes (t4g.micro) ≈ **$25/mes adicionales**.

## Pendiente — decisión del usuario, no tomada acá

El bastion es infraestructura explícitamente temporal (así se diseñó desde el principio de la fase). Con la validación ya completa, no hay una razón activa para dejarlo corriendo. Siguiendo la instrucción permanente de no destruir recursos de AWS sin indicación explícita, **queda desplegado** — es una sugerencia para la próxima interacción, no una acción tomada.
