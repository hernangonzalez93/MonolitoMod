# Fase 12 — Lambda consumidor de SQS

## Objetivo

Cierra el pipeline async: un Lambda dispara con cada mensaje de la cola de la Fase 11, se conecta a la RDS privada de la Fase 10 (via las subredes/SG que la Fase 9 y 10 ya habían preparado) y persiste la compra.

## Contexto/decisiones

### `.NET 10` es runtime administrado de Lambda — verificado antes de asumir nada

Como toda la solución apunta a `net10.0` (`Directory.Build.props`), antes de diseñar nada se confirmó contra la documentación oficial de AWS que `dotnet10` es un runtime administrado real (soportado hasta nov. 2028), no algo que hubiera obligado a bajar a .NET 8 o usar imagen de contenedor. AWS solo agrega como runtime administrado las versiones LTS/STS que decide soportar — no se podía asumir que .NET 10 estuviera cubierto.

### Sin EF Core — Npgsql directo

Para una función tan chica (deserializar un mensaje, insertar 2 tablas), el costo de arranque en frío que agrega un ORM completo no se justifica en Lambda. Se usó Npgsql (ADO.NET) directo. Esquema minimo, creado de forma idempotente (`CREATE TABLE IF NOT EXISTS`) en el primer arranque en frío — no hay mecanismo de migraciones formal todavía porque no hay forma de aplicar una migración externa sin acceso a la RDS (eso lo resuelve recién la Fase 13).

### Proyecto sin EF Core, sin mocking framework, reutilizando `MonolitoMod.Contracts`

El Lambda referencia el mismo proyecto `MonolitoMod.Contracts` que usa la API — deserializa `PurchaseCreatedEvent` con el mismo tipo que la API serializó al publicar a SQS (Fase 11), sin duplicar la forma del contrato en dos lados.

### Credenciales: Secrets Manager, cacheadas por el tiempo de vida del entorno de ejecución

El Lambda lee `DB_SECRET_ARN` (Fase 10) y arma la connection string en el primer arranque en frío, cacheándola en un campo estático — evita pedirle el secreto a Secrets Manager en cada invocación mientras el entorno de ejecución siga "caliente" (Lambda reutiliza el proceso entre invocaciones cercanas en el tiempo).

### `batch_size = 1` en el event source mapping

Con un batch más grande, una excepción en un solo mensaje reintentaría el lote entero (a menos que se implemente "partial batch response", más complejo de manejar). Con `batch_size = 1`, el radio de una falla queda acotado a ese mensaje puntual — trade-off consciente de simplicidad sobre throughput, razonable para el volumen de este estudio.

### Cómo se genera el artefacto de despliegue (dos pasos, no uno)

A diferencia de Fargate (donde `docker build` compila y empaqueta en un solo comando), el Lambda se arma en **dos pasos, en dos herramientas distintas**, sin nada automático conectándolos:

1. **`dotnet publish`** (manual) compila el C# y deja las DLLs + `.runtimeconfig.json` sueltas en `src/Lambda/MonolitoMod.Lambda.PurchasePersister/publish/`. Este es el primer artefacto: el resultado crudo del build, todavía sin empaquetar.

2. **`data "archive_file" "lambda"`** en `terraform/persistence/lambda.tf` — un *data source* de Terraform (no un `resource`: no crea nada en AWS). Corre **localmente**, en el momento en que se ejecuta `terraform plan`/`apply`, y comprime lo que en ese instante haya en `publish/` hacia `terraform/persistence/build/purchase-persister.zip`. Este .zip es el segundo artefacto, el que realmente sube a AWS.

```hcl
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/Lambda/MonolitoMod.Lambda.PurchasePersister/publish"
  output_path = "${path.module}/build/purchase-persister.zip"
}

resource "aws_lambda_function" "purchase_persister" {
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  # ...
}
```

`source_code_hash` es el SHA256 del contenido del .zip. En cada `terraform plan`, Terraform recalcula ese hash contra lo que hay en `publish/` en ese momento y lo compara con el que quedó guardado en el state la última vez que se aplicó — si difieren, el plan muestra `1 to change` y `apply` sube el .zip nuevo (exactamente lo que pasó al corregir el incidente de abajo). Si no cambió nada, ni se molesta en resubirlo.

**El detalle importante, para no pisarse en el futuro**: Terraform no compila C# ni le importa si el código fuente cambió — solo compara el contenido de `publish/`. Si se edita `Function.cs` y se corre `terraform apply` directo, **sin volver a correr `dotnet publish` antes**, Terraform re-empaqueta y "actualiza" la función con el código *viejo*, sin ninguna advertencia — porque desde su perspectiva, `publish/` no cambió. El orden manual (`dotnet publish` → recién después `terraform plan`/`apply`) es una disciplina que hay que sostener a mano, el tooling no la garantiza. Esto es justo lo que en la Fase 7 se resolvió para Fargate automatizando todo con CI/CD (GitHub Actions siempre reconstruye desde cero antes de desplegar); el Lambda todavía no tiene ese pipeline — quedó manual, igual que Fargate estaba antes de la Fase 7 — y sería una automatización natural a agregar más adelante.

## Incidente real: `.runtimeconfig.json` faltante — el Lambda no arrancaba

Primer despliegue: el Lambda fallaba en **todas** las invocaciones, incluso antes de llegar al código propio:
```
Error: .NET binaries for Lambda function are not correctly installed in the /var/task directory
of the image when the image was built. The /var/task directory is missing the required
.runtimeconfig.json file.
```
Causa: el proyecto es una **librería de clases** (`Microsoft.NET.Sdk` sin `<OutputType>Exe</OutputType>`) — `dotnet publish` no genera `.runtimeconfig.json` para librerías por defecto, solo para ejecutables. El *runtime bootstrap* administrado de Lambda sí necesita ese archivo para inicializar el host de .NET, aunque el ensamblado en sí nunca se "ejecute" como un .exe tradicional.

**Fix**: `<GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>` en el `.csproj`, que fuerza la generación aunque el `OutputType` sea `Library`. Se verificó el archivo presente en la carpeta de publish antes de volver a aplicar Terraform, en vez de asumir que el fix había funcionado.

## Confirmación real (accidental) de que la Dead-Letter Queue funciona

El mensaje que había quedado pendiente desde la Fase 11 (compra de prueba `widget-sqs`) intentó procesarse con el Lambda roto, falló 3 veces (`maxReceiveCount = 3`, Fase 11) y **SQS lo movió solo a `purchases-dlq`** — exactamente el comportamiento diseñado, aunque disparado por un bug en vez de una prueba intencional. Confirmado con `aws sqs get-queue-attributes` antes y después del fix.

## Validación real tras el fix

```bash
curl -s -X POST http://<alb>/api/purchases -d '{"customerEmail":"fase12-validacion@example.com","items":[{"productId":"widget-lambda","quantity":7}]}' ...
# 202 Accepted, purchaseId 9852b728-...

aws logs tail /aws/lambda/monolitomod-data-purchase-persister --since 2m
# "Persistida la compra 9852b728-8696-4706-a767-72c432c812ff (1 items)." — sin errores

aws sqs get-queue-attributes --queue-url .../monolitomod-data-purchases --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
# {"ApproximateNumberOfMessages": "0", "ApproximateNumberOfMessagesNotVisible": "0"}
```
El mensaje se procesó y se borró de la cola solo — SQS borra automáticamente un mensaje cuando la invocación del Lambda termina sin error. El log "Persistida la compra..." se imprime únicamente después de que el `COMMIT` de la transacción tuvo éxito, así que su presencia es evidencia (indirecta, no una consulta directa a la tabla) de que el insert funcionó.

**Lo que queda pendiente para la Fase 13**: confirmar con un `SELECT` real contra `purchases`/`purchase_items` que la fila efectivamente está ahí — todavía no hay forma de conectarse a la RDS privada desde afuera (el bastion + SSM sigue siendo tema de esa fase).

## Pasos ejecutados

```bash
# Proyecto nuevo + build local
# src/Lambda/MonolitoMod.Lambda.PurchasePersister/ (csproj, Function.cs)
dotnet build MonolitoMod.slnx -c Release   # 0 errores, 0 warnings

# Publish manual (paso previo a Terraform, igual que el push manual de la Fase 6)
dotnet publish src/Lambda/MonolitoMod.Lambda.PurchasePersister/MonolitoMod.Lambda.PurchasePersister.csproj \
  -c Release -r linux-arm64 --self-contained false \
  -o src/Lambda/MonolitoMod.Lambda.PurchasePersister/publish

cd terraform/persistence
terraform init      # nuevo provider hashicorp/archive ~> 2.0 (resolvió 2.8.0)
terraform plan -out tfplan.out    # 7 to add
terraform apply "tfplan.out"      # FALLA en runtime (ver incidente arriba)

# Fix del .csproj, republish, replan (0 to add, 1 to change), reapply
terraform apply "tfplan.out"

# Validación real end-to-end (parcial, ver nota arriba)
curl -s -X POST http://<alb>/api/purchases ...
aws logs tail /aws/lambda/monolitomod-data-purchase-persister --since 2m
aws sqs get-queue-attributes ...
```

## Archivos creados/modificados

- `src/Lambda/MonolitoMod.Lambda.PurchasePersister/MonolitoMod.Lambda.PurchasePersister.csproj`, `Function.cs`
- `MonolitoMod.slnx` — proyecto agregado
- `terraform/persistence/providers.tf` — provider `hashicorp/archive`
- `terraform/persistence/lambda.tf` — IAM role, log group, función, event source mapping
- `terraform/persistence/outputs.tf` — `rds_address`, `rds_port`, `lambda_function_name`

## Resultado final de esta fase

- Lambda `monolitomod-data-purchase-persister` corriendo dentro de la VPC privada, disparado por SQS, escribiendo (según toda la evidencia indirecta disponible) en RDS.
- Dead-Letter Queue validada en la práctica, aunque de forma no planeada.
- Permisos de mínimo privilegio: solo `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes` en la cola puntual, y `secretsmanager:GetSecretValue` en el secreto puntual — más las 2 políticas administradas de AWS para VPC/logs.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 13**: confirmar con una query real (`SELECT`) que las filas están en `purchases`/`purchase_items` — requiere resolver el acceso a la RDS privada (bastion + SSM Session Manager, como quedó acordado).
- [ ] El mensaje que cayó en la DLQ por el bug del `.runtimeconfig.json` sigue ahí — se puede inspeccionar o purgar en la Fase 13.
