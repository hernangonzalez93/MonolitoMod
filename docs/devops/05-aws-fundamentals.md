# Fase 5 — Fundamentos AWS (IAM, Budgets, CLI)

## Objetivo

Dejar la cuenta de AWS personal en condiciones seguras para empezar a crear infraestructura real en la Fase 6 (Terraform + Fargate): un usuario IAM de trabajo (nunca el root), la CLI y Terraform instalados localmente, y una alarma de presupuesto activa **antes** de crear el primer recurso que pueda costar dinero.

## Contexto/decisiones

### Por qué esta fase es distinta a las anteriores

Todas las fases previas (0 a 4) se podían automatizar de punta a punta porque el asistente tenía las herramientas (`git`, `gh`, `kubectl`, `docker`) ya autenticadas o autenticables sin tocar credenciales sensibles del usuario. **AWS es distinto**: crear la cuenta, iniciar sesión como root, activar MFA y generar claves de acceso de un usuario IAM son acciones que involucran contraseñas y verificación humana — quedan fuera de lo que el asistente puede/debe hacer. Esta fase se ejecutó de forma híbrida: el usuario hizo el trabajo en la consola web de AWS (cuenta, IAM, MFA, claves), el asistente instaló las herramientas locales y configuró lo que sí se puede hacer por CLI una vez autenticado.

### Usuario IAM con `AdministratorAccess`, no el root

Se creó el usuario `monolitomod-terraform` con la política administrada `AdministratorAccess`, en vez de una política de mínimo privilegio recortada por servicio (EC2, ECS, ECR, RDS, EKS, IAM para crear roles, S3 para estado de Terraform, budgets, etc.).

**Trade-off reconocido explícitamente**: en un entorno de producción o compartido, `AdministratorAccess` sobre un único usuario de CLI sería una mala práctica. Acá se aceptó a propósito porque:
- Es una cuenta personal, aislada, sin otros usuarios ni cargas de trabajo reales.
- El plan de estudio toca muchos servicios distintos (Fargate, ECR, RDS, EKS, IAM, Terraform state) — armar una política mínima de entrada implicaría ir agregando permisos a mitad de cada fase, mucha fricción para el objetivo de aprendizaje.
- El usuario root (que si puede hacer daño real: cerrar la cuenta, cambiar el método de pago) quedó completamente al margen del uso diario, con MFA activado.

### `aws configure` lo corrió el usuario, no el asistente

Ingresar Access Key ID / Secret Access Key es exactamente el tipo de credencial que el asistente tiene prohibido manejar. El usuario corrió `aws configure` en su propia terminal; el asistente solo verificó el resultado con un comando de **solo lectura**:
```bash
aws sts get-caller-identity
```
que confirma *quién* está autenticado sin exponer ni tocar las claves. Resultado: usuario `monolitomod-terraform`, cuenta `148142121824`, región `us-east-1`.

### Instalación de herramientas vía `winget`

`aws` cli y `terraform` no estaban instalados. Se instalaron con el gestor de paquetes de Windows:
```powershell
winget install --id Amazon.AWSCLI -e --accept-source-agreements --accept-package-agreements
winget install --id Hashicorp.Terraform -e --accept-source-agreements --accept-package-agreements
```
**Detalle práctico**: `winget` actualiza el `PATH` a nivel de registro de Windows, pero una sesión de shell ya abierta no lo relee automáticamente. Hubo que refrescar `$env:Path` manualmente dentro de la sesión de trabajo para que `aws`/`terraform` se reconocieran como comandos. Una terminal nueva abierta después de la instalación no tiene este problema.

### Budget de AWS — por qué antes que cualquier otro recurso

Se creó un `AWS Budget` de **$5 USD mensuales** con dos umbrales de notificación por email (a `hernanc.9@hotmail.com`, confirmado explícitamente antes de crear el recurso):
- 80% del gasto real ($4) → aviso temprano
- 100% del gasto real ($5) → aviso de que ya se alcanzó el límite

Se usó `AWS Budgets` (no una alarma clásica de CloudWatch Billing) porque no depende de habilitar primero la opción legacy "Receive Billing Alerts" en Preferencias de Facturación, y da más flexibilidad de umbrales. Es gratuito — AWS Budgets no cobra por los primeros presupuestos de una cuenta.

**Importante**: un Budget de AWS **avisa**, no bloquea ni cancela recursos automáticamente. Sigue siendo responsabilidad de cada fase (especialmente Fargate/EKS/RDS) destruir lo que no se esté usando activamente (`terraform destroy`, `eksctl delete cluster`, etc.) — el budget es la red de seguridad para notar un descuido, no un freno automático.

## Pasos ejecutados

```bash
# --- Local, por el asistente ---
winget install --id Amazon.AWSCLI -e --accept-source-agreements --accept-package-agreements
winget install --id Hashicorp.Terraform -e --accept-source-agreements --accept-package-agreements

# --- En la consola web de AWS, por el usuario (root con MFA) ---
# IAM > Usuarios > Crear usuario "monolitomod-terraform"
#   - Sin acceso a la consola (solo CLI)
#   - Política administrada: AdministratorAccess
#   - Credenciales de seguridad > Crear clave de acceso (uso: CLI)

# --- En su propia terminal, por el usuario ---
aws configure
# Access Key ID / Secret Access Key / región us-east-1 / output json

# --- Verificación, por el asistente (solo lectura, sin tocar credenciales) ---
aws sts get-caller-identity
# {"UserId": "...", "Account": "148142121824", "Arn": "arn:aws:iam::148142121824:user/monolitomod-terraform"}
aws configure get region   # us-east-1

# --- Budget, por el asistente (con confirmación explícita del email antes de crear) ---
aws budgets create-budget --account-id 148142121824 \
  --budget file://budget.json \
  --notifications-with-subscribers file://budget-notifications.json

# Verificación
aws budgets describe-budget --account-id 148142121824 --budget-name monolitomod-monthly-5usd
aws budgets describe-notifications-for-budget --account-id 148142121824 --budget-name monolitomod-monthly-5usd
```

`budget.json`:
```json
{
  "BudgetName": "monolitomod-monthly-5usd",
  "BudgetLimit": { "Amount": "5", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
```

`budget-notifications.json`: dos notificaciones (`ACTUAL` / `GREATER_THAN` / 80 y 100, `ThresholdType: PERCENTAGE`), ambas con suscriptor `EMAIL` a `hernanc.9@hotmail.com`.

## Resultado final de esta fase

- `aws` y `terraform` instalados y funcionando localmente.
- Usuario IAM `monolitomod-terraform` con `AdministratorAccess`, autenticado vía CLI — el root queda fuera del uso diario, con MFA.
- Budget mensual de $5 USD activo, `ActualSpend: $0.0`, con alertas por email al 80% y 100%.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 6**: primer uso real de Terraform — provisionar ECS Fargate. El usuario `monolitomod-terraform` ya tiene los permisos necesarios.
- [ ] Recordatorio para cada fase con recursos en AWS (6 a 12): destruir lo que no esté en uso activo entre sesiones de estudio (`terraform destroy` / `eksctl delete cluster`), el Budget solo avisa, no destruye nada solo.
