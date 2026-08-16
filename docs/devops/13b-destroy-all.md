# Addendum — Destrucción completa de toda la infraestructura AWS

No es una fase numerada del plan: es el cierre del ciclo completo hasta la Fase 13, pedido explícitamente por el usuario tras validar el flujo end-to-end (túnel SSM a la RDS funcionando). A diferencia del addendum de la Fase 8b (que destruyó solo `terraform/fargate`), acá se destruyeron **los dos módulos raíz** — `terraform/fargate` y `terraform/persistence` — dejando la cuenta en $0.

## Paso 0 — Cortar el túnel SSM abierto

Antes de destruir nada, había un túnel de `AWS-StartPortForwardingSessionToRemoteHost` corriendo en background desde la Fase 13 (RDS accesible en `localhost:5432`). Se mató el proceso (`aws.exe` + `session-manager-plugin.exe`) antes de tocar Terraform — un `destroy` con una sesión SSM activa contra el bastion no es un problema en sí (el bastion también se destruye), pero dejar procesos huérfanos apuntando a recursos que están por desaparecer no tiene sentido.

## Paso 1 — Preview de ambos destroys

```bash
cd terraform/persistence
terraform plan -destroy -out tfplan-destroy.out    # 39 to destroy

cd terraform/fargate
terraform plan -destroy -out tfplan-destroy.out    # 18 to destroy
```

57 recursos en total. Los dos planes se revisaron antes de aplicar nada — mismo criterio que en cualquier `apply`, un `destroy` no es menos revisable solo por ir en la dirección contraria.

## Paso 2 — Ejecutar ambos en paralelo

Al ser dos *state* independientes (decisión de diseño desde la Fase 9: `fargate` y `persistence` no comparten backend ni se referencian por *remote state*), se lanzaron los dos `apply "tfplan-destroy.out"` en paralelo, uno por módulo, sin ningún orden de dependencia entre ellos.

```bash
# terraform/persistence
terraform apply "tfplan-destroy.out"

# terraform/fargate
terraform apply "tfplan-destroy.out"
```

### `fargate`: patrón ya conocido, ~6 minutos

`Apply complete! Resources: 0 added, 0 changed, 18 destroyed.` El `aws_ecs_service.api` volvió a ser el recurso más lento (~6 minutos), reconfirmando el hallazgo de la Fase 8b: el `deregistration_delay` de 300s del target group nunca se sobreescribió, así que ECS siempre espera ese drenaje completo antes de dar de baja el servicio. El resto (IAM roles, OIDC provider, ALB, ECR, security groups) se destruyó en segundos.

### `persistence`: incidente nuevo — ENIs de Lambda "Hyperplane"

Este destroy tardó bastante más de lo esperado: la función Lambda y el bastion se destruyeron rápido, pero el `aws_security_group.lambda` y los dos `aws_subnet.private` quedaron **"Still destroying..." durante más de 20 minutos**.

**Diagnóstico** (verificado con la API, no asumido): mientras el destroy seguía colgado, se consultó directamente

```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'NetworkInterfaces[*].[NetworkInterfaceId,Status,Description,InterfaceType]'
```

y aparecieron **4 ENIs** con `InterfaceType: lambda`, estado `in-use`, descripción `AWS Lambda VPC ENI-monolitomod-data-purchase-persister` — es decir, la función Lambda ya no existía (Terraform la había borrado), pero sus interfaces de red seguían activas y ancladas al Security Group y a los subnets, bloqueando el borrado de ambos.

**Causa raíz**: desde 2019, las funciones Lambda con acceso a VPC usan ENIs compartidas de tipo *Hyperplane* en vez de una ENI dedicada por función. Esto hizo mucho más rápida la *creación* de funciones en VPC (antes tardaba minutos), pero como contrapartida la *liberación* de esas ENIs al borrar la función es un proceso asíncrono del lado de AWS, fuera del control de Terraform — puede tardar desde unos minutos hasta ~20-30 minutos en casos normales. `terraform destroy` no falla ni se cuelga por un bug propio: reintenta el `DeleteSecurityGroup`/`DeleteSubnet` contra la API real de AWS, que sigue devolviendo `DependencyViolation` hasta que AWS reclama las ENIs por su cuenta.

No hay ninguna acción que acelerar esto desde Terraform o la CLI — es esperar. En este caso se resolvió solo, sin intervención, en el minuto ~21 para el Security Group y ~17 para los subnets.

```
aws_subnet.private[0]: Destruction complete after 17m18s
aws_security_group.lambda: Destruction complete after 21m13s
aws_subnet.private[1]: Destruction complete after 17m28s
aws_vpc.data: Destruction complete after 1s

Apply complete! Resources: 0 added, 0 changed, 39 destroyed.
```

## Verificación (AWS CLI, no solo el output de Terraform)

Mismo criterio que en la Fase 8b y en toda la sesión: no confiar en que el `apply` haya salido "Apply complete" como única prueba, sino consultar los servicios reales.

```bash
aws ecs list-clusters                                    # vacío
aws rds describe-db-instances                             # vacío
aws lambda list-functions                                  # vacío
aws sqs list-queues                                         # vacío
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped
                                                              # vacío
aws ec2 describe-vpcs --filters Name=isDefault,Values=false # vacío (solo quedan las VPCs default de AWS)
aws ecr describe-repositories                                # vacío
aws iam list-open-id-connect-providers                        # vacío
aws elbv2 describe-load-balancers                              # vacío
aws iam list-roles --query "Roles[?contains(RoleName,'monolitomod')]"  # vacío
aws secretsmanager list-secrets                                  # vacío (el secret de manage_master_user_password se borró junto con la RDS)
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[?State!=`deleted`]'  # vacío
```

Todo confirmado vacío en los dos módulos.

## Resultado final

- **57 recursos destruidos** (39 en `persistence` + 18 en `fargate`), 0 errores.
- Cuenta AWS en **$0** de recursos activos relacionados con el proyecto.
- Incidente nuevo documentado y con causa raíz real: las ENIs Hyperplane de Lambda en VPC no se liberan de forma síncrona al borrar la función, y pueden extender un `terraform destroy` bastante más allá de lo que sugieren los recursos "grandes" (RDS, ECS) por sí solos.
- Ambos *states* de Terraform (`terraform/fargate` y `terraform/persistence`) quedaron vacíos (`terraform state list` sin salida en ambos).

## Para recrear todo

```bash
cd terraform/fargate
terraform apply

cd terraform/persistence
terraform apply
```

Recrea los 57 recursos. Cosas que **van a cambiar** respecto a como estaban:
- ALB con DNS público nuevo (igual que en la Fase 8b).
- ECR vacío — requiere un primer push antes de que Fargate tenga una imagen que correr.
- RDS con un endpoint nuevo y una contraseña nueva generada por Secrets Manager (`manage_master_user_password` no reutiliza secrets anteriores).
- Cola SQS con una URL nueva — la variable `sqs_queue_name` en `terraform/fargate` referencia por *nombre*, no por ARN fijo, así que en teoría no hace falta tocarla si el nombre no cambia; igual conviene revisar el `data` source después de recrear.
- El bastion de la Fase 13 **no** se recrea automáticamente (era temporal a propósito) — si se necesita validar de nuevo contra la RDS, hay que volver a aplicar `bastion.tf` o crear uno nuevo.

## Archivos modificados

Ninguno — este addendum documenta un cambio de **estado** (recursos destruidos), no de código Terraform. No hay diffs en `.tf`.
