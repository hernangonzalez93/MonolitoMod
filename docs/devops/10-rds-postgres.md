# Fase 10 — RDS Postgres

## Objetivo

Provisionar la base de datos Postgres que el Lambda de la Fase 12 va a usar para persistir las compras — dentro de la VPC privada de la Fase 9, sin ninguna ruta de red hacia internet.

## Contexto/decisiones

### Versión del engine: verificada, no asumida

Antes de escribir `engine_version`, se consultó qué versiones mayores de Postgres soporta RDS en esta cuenta/región:
```bash
aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[?IsMajorVersion==true].EngineVersion"
```
La más reciente disponible es la 18. Se usó `engine_version = "18"` (solo el major, no un patch fijo) — mismo criterio que `~> 6.0` para providers o `v6` para GitHub Actions: se deja que AWS administre el minor (`auto_minor_version_upgrade` queda en `true` por default), y la versión exacta resuelta en esta corrida quedó registrada como `18.3` al verificar después del apply.

También se verificó que la clase de instancia elegida existiera para esa versión antes de usarla:
```bash
aws rds describe-orderable-db-instance-options --engine postgres --engine-version 18.4 --query "...DBInstanceClass"
```
`db.t4g.micro` (Graviton, la más barata disponible) confirmada como válida.

### Incidente evitado antes de aplicar: dependencia circular entre Security Groups

El diseño necesita que el SG de `lambda` permita salida hacia el SG de `rds`, y que el SG de `rds` permita entrada solo desde el SG de `lambda` — cada uno necesita el ID del otro. Escribir esto como bloques `ingress`/`egress` **inline** dentro de cada `aws_security_group` (como se hizo para los SGs de la Fase 6) habría creado una dependencia circular real: para crear el SG de lambda hace falta el ID del SG de rds, y viceversa. Se detectó este problema releyendo el archivo antes de correr `terraform plan` (no hizo falta que Terraform lo rechazara para darse cuenta).

**Solución**: declarar ambos Security Groups vacíos, y las reglas que se referencian mutuamente como recursos aparte (`aws_vpc_security_group_ingress_rule` / `_egress_rule`, los recursos más nuevos de la v6 del provider, uno por regla en vez del bloque inline plural de la generación anterior). Terraform puede crear los dos SGs primero, y recién después las reglas — ya con ambos IDs disponibles.

### El SG del Lambda se crea en esta fase, sin que el Lambda exista todavía

`aws_security_group.lambda` se declara acá únicamente para que el SG de RDS pueda decir "solo acepto conexiones desde esto" desde el primer momento. La Fase 12 va a desplegar el Lambda usando este mismo Security Group — no va a hacer falta volver a tocar la configuración de acceso de RDS en ese momento.

### `manage_master_user_password = true` — la contraseña nunca pasa por nuestro código

En vez de generar una contraseña con el provider `random` de Terraform y asignarla a mano (lo que la dejaría en texto plano dentro de `terraform.tfstate`), se usó la función nativa de RDS: `manage_master_user_password = true` hace que **RDS mismo** genere la contraseña y la guarde en Secrets Manager — ni el código de Terraform ni el state llegan a contener el valor real en ningún momento. Verificado después del apply:
```bash
aws secretsmanager describe-secret --secret-id <rds_secret_arn>
```
El secreto (`rds!db-506a62d1-dc5f-4518-8f18-c54e33c1f060`) existe, gestionado por RDS.

### Configuración pensada para minimizar costo y fricción de un proyecto de estudio

- `instance_class = "db.t4g.micro"` — la más chica/barata disponible.
- `multi_az = false` — una sola instancia; alta disponibilidad no aporta nada a un ejercicio de aprendizaje y duplicaría el costo.
- `allocated_storage = 20` (GB, el mínimo permitido).
- `skip_final_snapshot = true` — sin esto, `terraform destroy` quedaría esperando (y pagando) un snapshot final antes de poder borrar la instancia.
- `deletion_protection = false` — a propósito, para que destruir/recrear durante el estudio sea simple (trade-off consciente: no hay "seguro" contra un destroy accidental).

### `publicly_accessible = false` — la garantía central de la fase

No es solo una bandera: como la VPC de la Fase 9 no tiene Internet Gateway, no existiría ninguna ruta de red para llegar a esta base desde internet aunque `publicly_accessible` estuviera en `true`. Es una segunda capa de la misma protección, no la única.

## Pasos ejecutados

```bash
# Verificaciones antes de escribir código
aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[?IsMajorVersion==true].EngineVersion"
aws rds describe-orderable-db-instance-options --engine postgres --engine-version 18.4 --query "...DBInstanceClass"

cd terraform/persistence
# security_groups.tf (SGs + reglas separadas), rds.tf, variables.tf, outputs.tf actualizados

terraform fmt
terraform validate
terraform plan -out tfplan.out    # 7 to add
terraform apply "tfplan.out"      # ~6m11s, la mayor parte esperando a que RDS termine de aprovisionar

# Verificación real
aws rds describe-db-instances --db-instance-identifier monolitomod-data-db \
  --query "DBInstances[0].{status:DBInstanceStatus,publiclyAccessible:PubliclyAccessible,az:AvailabilityZone,engineVersion:EngineVersion}"
# {"status": "available", "publiclyAccessible": false, "az": "us-east-1b", "engineVersion": "18.3"}

aws secretsmanager describe-secret --secret-id <rds_secret_arn>
```

## Archivos creados/modificados

- `terraform/persistence/security_groups.tf` — SGs de `lambda` y `rds` + 3 reglas como recursos separados (evita el ciclo).
- `terraform/persistence/rds.tf` — DB Subnet Group + instancia.
- `terraform/persistence/variables.tf` — `db_instance_class`, `db_engine_version`, `db_name`, `db_username`.
- `terraform/persistence/outputs.tf` — `lambda_security_group_id`, `rds_endpoint`, `rds_secret_arn`.

## Resultado final de esta fase

- RDS Postgres 18.3 corriendo, `available`, `publiclyAccessible: false`, en la VPC privada de la Fase 9.
- Credenciales en Secrets Manager, gestionadas por RDS — nunca vistas en texto plano.
- Costo aproximado si queda corriendo sin parar: ~$0.016/h de cómputo + ~$2.30/mes de storage ≈ **$14/mes**, sumado a los ~$29/mes de los VPC Endpoints de la Fase 9.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 12 (Lambda)**: usar `lambda_security_group_id` al desplegar la función, y `rds_secret_arn` para que el Lambda pueda leer las credenciales vía el VPC Endpoint de Secrets Manager de la Fase 9.
- [ ] **Fase 13 (Validar)**: sigue pendiente definir cómo consultar esta base desde afuera para validar (SSM Session Manager port-forwarding, lo más probable) — no se resolvió en esta fase.
