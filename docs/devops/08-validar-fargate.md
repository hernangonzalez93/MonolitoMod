# Fase 8 — Validar despliegue en Fargate

## Objetivo

El flujo feliz (`/health`, compra exitosa) ya se había probado dos veces (Fase 6 manual, Fase 7 automatizado) — repetirlo tal cual no agregaba información nueva. Esta fase se enfocó en tres validaciones que **todavía no se habían hecho**: camino de error, evidencia real de que la lógica de negocio corrió (no solo que la API respondió), y resiliencia ante la caída de una task.

## 1. Camino de error (validación)

```bash
curl -s -X POST http://monolitomod-alb-.../api/purchases -H "Content-Type: application/json" -d '{"customerEmail":"","items":[]}' -i
```
Resultado: `400 Bad Request`, `application/problem+json`, con el mensaje de validación esperado (`CustomerEmail and at least one valid item are required.`) — confirma que la validación de `Program.cs` funciona igual en Fargate que en local/Kubernetes, y que el ALB no altera ni bloquea respuestas de error.

## 2. Hallazgo real: no se puede confirmar por logs qué módulos procesaron el evento

Se intentó correlacionar una compra con un producto de nombre distintivo (`widget-fase8`) contra los logs de CloudWatch, esperando encontrar evidencia de que `AdjustInventoryOnPurchaseCreatedHandler` y `SendPurchaseConfirmationHandler` corrieron:

```bash
aws logs filter-log-events --log-group-name /ecs/monolitomod-api --filter-pattern "widget-fase8"
# (sin resultados)
```

Revisando el log completo (`aws logs tail /ecs/monolitomod-api --since 5m`), la razón quedó clara: **la aplicación no tiene logging de negocio**. Los `logConfiguration` de la task definition (Fase 6) capturan correctamente la salida estándar del contenedor, pero lo único que se loguea es el logging *genérico* de ASP.NET Core (`Request starting/finished HTTP...`, con método, path y status code) — ninguno de los handlers (`AdjustInventoryOnPurchaseCreatedHandler`, `SendPurchaseConfirmationHandler`) llama a `ILogger` en ningún punto (se puede confirmar leyendo el código: solo hacen `store.Record(...)`).

Lo que sí se pudo confirmar por log: que la request de error (400) y la request válida (202) llegaron al contenedor y se procesaron en los tiempos esperados:
```
Request finished HTTP/1.1 POST .../api/purchases - 400 - application/problem+json 32.1323ms
Request finished HTTP/1.1 POST .../api/purchases - 202 - application/json;+charset=utf-8 12.8931ms
```

**Conclusión honesta**: desde afuera (sin acceso al proceso), hoy solo se puede validar el contrato HTTP de la API, no la lógica interna de los módulos — a diferencia de local (Fase 0/1), donde el test de integración sí puede inspeccionar `IInventoryActivityStore`/`INotificationStore` directamente porque corre en el mismo proceso. Queda como mejora pendiente (no aplicada en esta fase, es un cambio de código de aplicación fuera del alcance de "validar infraestructura"): agregar logging estructurado en los handlers, o esperar a la Fase 9, donde Postgres va a dar una forma real de verificar el estado persistido desde afuera (`SELECT` contra la base).

## 3. Prueba de resiliencia: matar la task activa y observar la auto-recuperación

```bash
# Identificar la task corriendo
aws ecs list-tasks --cluster monolitomod --service-name monolitomod-api
# task/monolitomod/3fa94c77bcd8414a964aafb6e9031316

# Matarla a propósito
aws ecs stop-task --cluster monolitomod --task <arn> --reason "Fase 8: prueba de resiliencia deliberada"
```

Secuencia observada, sin ninguna intervención manual después del `stop-task`:

| T+ | Evento |
|---|---|
| 0s | Task detenida a propósito |
| ~15s | `runningCount: 0`, `pending: 0` — el service todavía no reaccionó |
| ~35s | `runningCount: 1` — ECS ya lanzó una task **nueva** (`2e5a8a541a4549f1b6aedb331808a5f7`, ID distinto a la original) |
| — | Target group: la IP vieja (`172.31.5.210`) en `draining`, la nueva (`172.31.9.72`) ya `healthy` |
| — | `curl /health` contra el ALB público → `200 OK` |

Esto es exactamente la garantía que da un ECS **Service** (a diferencia de correr una task suelta): el `desired_count = 1` declarado en Terraform (Fase 6) se hace cumplir de forma continua — si algo mata una task (crash, mantenimiento del host, o alguien la mata a mano como acá), el scheduler la reemplaza sin que nadie tenga que reaccionar.

## Archivos creados/modificados

Ninguno — esta fase fue enteramente de validación contra la infraestructura ya desplegada, sin cambios de código ni de Terraform.

## Resultado final de esta fase

- Camino de error: validado, se comporta igual que en local/Kubernetes.
- Observabilidad: limitación real identificada y documentada (no hay logging de negocio) — no se resolvió en esta fase a propósito, para no mezclar "validar infra" con "cambiar código de la app".
- Resiliencia: validada con una caída real y deliberada — ECS repuso la task automáticamente, el ALB volvió a servir sin intervención manual.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 9**: al agregar Postgres, considerar si vale la pena resolver ahí mismo la falta de logging de negocio (o dejarlo como mejora aparte) — con una base de datos real, de todos modos va a haber una forma más directa de verificar el estado (`SELECT` en vez de logs).
- [ ] Con `desired_count = 1` hay una ventana breve sin ningún task sirviendo tráfico durante un reemplazo (se observó ~20-35s). Con `desired_count >= 2` esa ventana desaparecería (siempre quedaría al menos 1 task sana) — no se cambió en esta fase por mantener el costo mínimo, pero es un trade-off consciente a tener presente.
