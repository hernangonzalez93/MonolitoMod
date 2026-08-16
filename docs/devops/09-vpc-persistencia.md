# Fase 9 — VPC privada para persistencia (RDS + Lambda)

## Objetivo

Antes de esta fase, el plan original (una sola "Fase 9 — Postgres") se replanteó a pedido explícito del usuario: en vez de que la API escriba directo a Postgres vía EF Core, los eventos de compra se van a publicar a una cola SQS, y un Lambda va a hacer el poll de esa cola y persistir en RDS. Esta fase construye la base de red que ese Lambda y esa base de datos necesitan: una VPC privada, separada de la que usa Fargate/ALB.

## Contexto/decisiones

### Root module de Terraform separado (`terraform/persistence/`)

State propio, independiente de `terraform/fargate/`. No hay ninguna dependencia automática entre ambos — son dos preocupaciones distintas (cómputo público vs. datos privados) que conviene poder aplicar/destruir por separado.

### Por qué una VPC nueva y no modificar la VPC por defecto

La VPC por defecto (usada por Fargate/ALB desde la Fase 6) es enteramente pública, sin subredes privadas armadas. En vez de reformarla, se creó una **segunda VPC, completamente aislada de la primera**. Esto es seguro porque ninguno de los dos lados necesita hablar directo con el otro:
- Fargate solo va a hablar con **SQS** (Fase 11) — un servicio público de AWS, alcanzable sin importar en qué VPC esté Fargate.
- El Lambda (Fase 12) solo necesita **RDS** (en esta misma VPC nueva) y, vía VPC Endpoint, Secrets Manager/CloudWatch Logs.

Sin necesidad de comunicación directa entre las dos VPCs, no hace falta VPC Peering ni ningún otro puente — quedan simplemente aisladas.

### Sin Internet Gateway, sin NAT — solo VPC Endpoints

A diferencia de la VPC de Fargate (pública, con salida directa a internet), esta VPC es **100% privada**: no tiene Internet Gateway. La tabla de rutas de las subredes privadas (`aws_route_table.private`) no tiene ninguna ruta agregada a mano — solo queda la ruta `local` que AWS agrega sola para que las subredes se hablen entre sí dentro de la VPC. Verificado después del apply:
```bash
aws ec2 describe-route-tables --route-table-ids <id> --query "RouteTables[0].Routes"
# [{ "DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local", ... }]
```
Ninguna ruta hacia `0.0.0.0/0`. Es la garantía, en código y verificable, de que nada acá puede iniciar una conexión a internet.

Lo único que el futuro Lambda necesita llamar por fuera de esta VPC (Secrets Manager para las credenciales de RDS, CloudWatch Logs para poder loguear) se resuelve con **VPC Endpoints tipo Interface** — un camino privado directo dentro de la red de AWS, sin tocar internet en ningún punto.

### `enable_dns_hostnames`/`enable_dns_support` — necesarios, no opcionales

Ambos en `true` en la VPC. Sin esto, los VPC Endpoints con `private_dns_enabled = true` no podrían hacer que, por ejemplo, `secretsmanager.us-east-1.amazonaws.com` resuelva a la IP privada del endpoint — seguiría resolviendo a una IP pública, y como no hay ruta a internet, esa llamada fallaría directamente.

### Costo real: los VPC Endpoints, no la VPC en sí

La VPC, las subredes, la tabla de rutas y el security group no tienen costo. Los 2 VPC Endpoints Interface, desplegados en las 2 AZs (siguiendo la disponibilidad de las 2 subredes privadas), sí: **~$0.01/hora por AZ por endpoint** → `2 endpoints × 2 AZs × $0.01/h ≈ $0.04/h ≈ $29/mes` si quedan corriendo el mes completo, más el (bajo) costo de datos procesados. Se presentó esta cifra explícitamente antes de aplicar, y se confirmó desplegar en las 2 AZs (mayor disponibilidad) sobre la alternativa de 1 sola AZ (~$14.6/mes, con riesgo de que el Lambda quede sin acceso si AWS lo corre en la AZ sin endpoint).

## Pasos ejecutados

```bash
mkdir terraform/persistence
cd terraform/persistence
# providers.tf, variables.tf, data.tf, network.tf, outputs.tf — ver archivos

terraform init        # provider hashicorp/aws ~> 6.0, resolvió 6.60.0 (mismo que fargate/)
terraform fmt
terraform validate
terraform plan -out tfplan.out    # 9 to add
terraform apply "tfplan.out"

# Verificación real, no solo confiar en el plan
aws ec2 describe-route-tables --route-table-ids <id> --query "RouteTables[0].Routes"
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids <id1> <id2> --query "VpcEndpoints[].{service:ServiceName,state:State}"
```

## Archivos creados/modificados

- `terraform/persistence/providers.tf`, `variables.tf`, `data.tf`, `network.tf`, `outputs.tf`
- `terraform/persistence/.terraform.lock.hcl` (versionado, mismo criterio que en `terraform/fargate/`)

## Resultado final de esta fase

- VPC `monolitomod-data-vpc` (`10.0.0.0/16`), 2 subredes privadas en 2 AZs distintas, sin salida a internet — verificado, no asumido.
- 2 VPC Endpoints (`secretsmanager`, `logs`) en estado `available`, con DNS privado habilitado.
- Aislada de la VPC de Fargate/ALB — ninguna de las dos sabe que la otra existe, y no hace falta que lo sepan.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 10 (RDS)**: usar `private_subnet_ids` y necesitará su propio Security Group — el de los VPC Endpoints (`vpc_endpoints_security_group_id`) es solo para el tráfico hacia Secrets Manager/CloudWatch, no para el tráfico hacia la base de datos en sí.
- [ ] **Fase 12 (Lambda)**: correrá dentro de estas mismas subredes privadas; su Security Group va a necesitar permiso de salida hacia el SG de los VPC Endpoints (puerto 443) y hacia el SG de RDS (puerto 5432) — ninguno de los dos existe todavía.
