# Fase 11 — SQS

## Objetivo

La API publica cada compra también a una cola SQS, como un tercer consumidor del evento independiente del bus en memoria (Inventory/Notifications, sin tocar) — el primer eslabón del pipeline async que el Lambda de la Fase 12 va a completar.

## Incidente real: pasaba local, falló en CI — y con razón

Con el primer intento (`AddSingleton<IAmazonSQS>(new AmazonSQSClient())`), `dotnet test` pasaba en esta máquina pero falló en el runner de GitHub Actions con:
```
Amazon.Runtime.AmazonClientException : No RegionEndpoint or ServiceURL configured
```

`new AmazonSQSClient()` se ejecuta de forma **inmediata**, en el momento de registrar el singleton — no cuando alguien realmente pide `IAmazonSQS`. Localmente "funcionaba" solo porque el SDK de AWS encontró una región en `~/.aws/config` (configurado en la Fase 5 con `aws configure`) y la usó sin que nadie se lo pidiera explícitamente. El runner de GitHub Actions no tiene ese archivo — no hay ninguna razón para que lo tenga, ese job nunca toca AWS — así que la construcción fallaba ahí mismo, al arrancar el host de test.

Esto es, en los hechos, la razón de ser de CI: expuso una dependencia oculta de mi entorno local que el código no debería haber tenido. **Fix**: registrar una fábrica en vez de una instancia (`AddSingleton<IAmazonSQS>(_ => new AmazonSQSClient())`), para que la construcción quede diferida hasta el primer uso real — en el host de test, como `IPurchaseEventPublisher` está reemplazado por el fake, `IAmazonSQS` nunca llega a resolverse ni a construirse.

## Contexto/decisiones

### Cola principal + Dead-Letter Queue

`aws_sqs_queue.purchases` con `redrive_policy` apuntando a `aws_sqs_queue.purchases_dlq` (`maxReceiveCount = 3`). Si el futuro Lambda falla al procesar un mensaje 3 veces, SQS lo saca de la cola principal y lo mueve a la DLQ en vez de reintentarlo para siempre o perderlo — queda disponible para inspeccionar qué salió mal. `sqs_managed_sse_enabled = true` en ambas: cifrado en reposo gestionado por AWS, sin costo ni configuración extra.

### El cruce entre los dos módulos de Terraform, resuelto con un data source

La cola vive en `terraform/persistence/` (state propio, Fase 9). El permiso para publicarle vive en `terraform/fargate/` (state distinto, Fase 6). Sin usar `terraform_remote_state`, se resolvió con lo que ya se había anotado como plan en la Fase 9: un `data "aws_sqs_queue" "purchases" { name = var.sqs_queue_name }` en `terraform/fargate/`, que la busca por nombre. Funciona porque el nombre es predecible — lo definimos nosotros en ambos lados (`project_name + "-purchases"`).

### Task role — el permiso que faltaba desde la Fase 6

La nota que había quedado pendiente en `terraform/fargate/iam.tf` desde la Fase 6 ("si más adelante la aplicación necesitara llamar directo a una API de AWS, hará falta un segundo rol") se resolvió acá: `aws_iam_role.ecs_task`, con permiso de mínimo privilegio (`sqs:SendMessage`, acotado al ARN exacto de la cola) — distinto del `ecs_task_execution` que usa el *agente* de ECS. Se agregó `task_role_arn` a la task definition.

### `SQS_QUEUE_URL` y `AWS_REGION` como variables de entorno explícitas

La URL de la cola se resuelve en Terraform (vía el mismo data source) y se inyecta como variable de entorno del contenedor — la aplicación nunca la hardcodea. `AWS_REGION` también se agregó explícitamente: el SDK de AWS para .NET la resuelve automáticamente si existe, pero a diferencia de Lambda (donde es automática), no está garantizado que Fargate la agregue por su cuenta.

### Incidente evitado antes de aplicar: dependencia circular en los Security Groups

Al escribir el permiso de red, `aws_security_group.lambda` necesitaba apuntar al SG de `aws_security_group.rds` y viceversa. Igual que en la Fase 10, se detectó antes de correr `plan` y se evitó con reglas separadas en vez de bloques inline — mismo patrón, ya aplicado dos veces.

### Abstracción `IPurchaseEventPublisher` — por qué no inyectar `IAmazonSQS` directo

Al escribir el código, `dotnet test` empezó a fallar: el test de integración existente (`PurchaseEndpointTests`) no tiene `SQS_QUEUE_URL` configurada ni acceso real a AWS, así que el endpoint tiraba la excepción agregada a propósito (`SQS_QUEUE_URL no está configurada.`). En vez de suavizar esa excepción en producción (lo que escondería un error real de configuración) o agregar un mocking framework nuevo al repo (Moq/NSubstitute, que no se usa en ningún otro lado del proyecto), se introdujo una interfaz mínima de un solo método:

```csharp
public interface IPurchaseEventPublisher { Task PublishAsync(PurchaseCreatedEvent @event, CancellationToken cancellationToken); }
```

`SqsPurchaseEventPublisher` es la implementación real (usa `IAmazonSQS` + la config). El endpoint depende de la interfaz, no de SQS directo. El test de integración reemplaza la implementación por un `FakePurchaseEventPublisher` (una lista en memoria) vía `WebApplicationFactory.WithWebHostBuilder(...)` — mismo patrón de "sustituir un servicio real por un fake para el test" que ya existe implícitamente en el resto del proyecto (los stores in-memory de Inventory/Notifications), sin agregar dependencias nuevas. El test además ahora verifica que el publisher fue invocado, no solo que el bus en memoria funcionó — cobertura real, no solo "sigue compilando".

### Recrear `terraform/fargate/` completo

Como esa infraestructura se había destruido en el addendum de la Fase 8, aplicar este cambio recreó **los 18 recursos** de una sola vez: los 13 de la Fase 6, los 3 de la Fase 7 (OIDC), y los 2 nuevos de esta fase (task role + policy). El ALB volvió a levantar con un DNS público distinto (`monolitomod-alb-276120272...`).

## Pasos ejecutados

```bash
# terraform/persistence/
cd terraform/persistence
# sqs.tf nuevo
terraform plan -out tfplan.out    # 2 to add
terraform apply "tfplan.out"

# terraform/fargate/
cd ../fargate
# variables.tf (sqs_queue_name), iam.tf (task role + data source), ecs.tf (task_role_arn + env vars)
terraform plan -out tfplan.out    # 18 to add (recrea todo)
terraform apply "tfplan.out"

# Código: AWSSDK.SQS al csproj, Program.cs (IPurchaseEventPublisher), test actualizado
dotnet build MonolitoMod.slnx -c Release   # 0 errores, 0 warnings
dotnet test MonolitoMod.slnx -c Release    # 3/3 passing
```

## Archivos creados/modificados

- `terraform/persistence/sqs.tf`, `outputs.tf`
- `terraform/fargate/variables.tf`, `iam.tf`, `ecs.tf`
- `src/MonolitoMod.Api/MonolitoMod.Api.csproj` — `AWSSDK.SQS` 4.0.100.8 (verificada contra NuGet antes de fijarla)
- `src/MonolitoMod.Api/Program.cs` — `IPurchaseEventPublisher`/`SqsPurchaseEventPublisher`, publica a SQS además del bus en memoria
- `tests/MonolitoMod.Api.IntegrationTests/PurchaseEndpointTests.cs` — `FakePurchaseEventPublisher`, nueva aserción

## Pendientes / notas para la siguiente fase

- [ ] **Validación real end-to-end** (POST a la API nueva → confirmar mensaje en la cola) queda para después de que el pipeline de CI/CD termine de desplegar el código nuevo — se documenta en un commit de seguimiento una vez confirmado.
- [ ] **Fase 12 (Lambda)**: ya tiene todo lo que necesita de esta fase — `sqs_queue_arn` para el event source mapping, `lambda_security_group_id` (Fase 10) para la red, `rds_secret_arn` (Fase 10) para las credenciales.
- [ ] **Fase 13**: sigue pendiente el mecanismo de acceso a RDS para validar (bastion + SSM), según lo acordado.
