# Fase 4 — Kubernetes local con Docker Desktop

## Objetivo

Desplegar la API en un clúster de Kubernetes real (aunque local, de un solo nodo) usando manifiestos declarativos, como base de aprendizaje antes de repetir el mismo patrón en EKS (Fase 10). Validar Deployment, Service, probes y logs — no solo "que arranque", sino entender qué hace cada pieza.

## Contexto/decisiones

### Por qué Docker Desktop y no minikube/kind

Ya estaba instalado y habilitado (`kubectl cluster-info` respondió de entrada, contexto `docker-desktop`, nodo `Ready`). Ventaja clave sobre minikube/kind para este estudio: **Docker Desktop comparte el mismo daemon de Docker** entre el host y el clúster de Kubernetes — una imagen construida con `docker build` en el host es visible inmediatamente para los pods, sin necesidad de un registry intermedio ni de cargar la imagen manualmente al nodo (`kind load docker-image`, por ejemplo, sí lo requeriría).

### Namespace dedicado

`k8s/namespace.yaml` crea `monolitomod` en vez de usar `default`. Aísla los recursos de este estudio y permite limpiar todo con `kubectl delete namespace monolitomod` sin tocar nada más del clúster local.

### Imagen local, no la de GHCR

Se usó `monolitomod-api:local` (reconstruida de la Fase 1, cacheada) en vez de `ghcr.io/hernangonzalez93/monolitomod-api:latest` de la Fase 3. Motivo: el paquete en GHCR es **privado**, y usarlo aquí habría requerido crear un `imagePullSecret` con credenciales de registry — complejidad innecesaria para probar manifiestos localmente. En el Deployment:
```yaml
image: monolitomod-api:local
imagePullPolicy: Never
```
`imagePullPolicy: Never` es la parte importante: sin esto, kubelet intentaría descargar `monolitomod-api:local` de Docker Hub (el registry por defecto), fallaría (`ErrImagePull`), porque esa imagen solo existe en el daemon local.

### 2 réplicas, no 1

A propósito, para dos cosas: (1) comprobar en la práctica cómo reparte tráfico un Service entre varios pods (ver hallazgo más abajo), y (2) dejar una base `replicas: 2` ya establecida de cara a la Fase 12, donde el HPA va a escalar *a partir de* este mínimo.

### `resources.requests` — no es solo buena práctica, es un prerrequisito

Se definieron `requests` y `limits` de CPU/memoria en el contenedor. Más allá de evitar que un pod acapare el nodo, **`requests.cpu` es obligatorio para que el HPA de la Fase 12 funcione**: el autoescalado por CPU calcula el % de uso *contra* ese valor de referencia. Sin `requests.cpu`, el HPA no tiene con qué comparar el uso real.

### Readiness vs. Liveness — por qué dos probes distintas contra el mismo endpoint

Ambas apuntan a `/health` (el endpoint que ya existía desde el proyecto original, pensado originalmente solo para pruebas manuales), pero cumplen roles distintos:
- **readinessProbe** (`initialDelaySeconds: 2`, cada 5s): si falla, el pod se saca de los *endpoints* del Service — deja de recibir tráfico nuevo, pero sigue corriendo. Sirve para no enviar requests a un pod que está arrancando o temporalmente saturado.
- **livenessProbe** (`initialDelaySeconds: 10`, cada 10s): si falla de forma sostenida, Kubernetes **reinicia el contenedor**. El delay inicial es mayor a propósito, para no matar un pod que simplemente tarda un poco más en levantar.

### Service `ClusterIP`, no `LoadBalancer`

Docker Desktop tiene una particularidad: sabe exponer `type: LoadBalancer` automáticamente en `localhost`, algo que ningún otro clúster hace por defecto (en EKS, un `LoadBalancer` real aprovisiona un ELB de AWS, con costo y demora). Se usó `ClusterIP` + `kubectl port-forward` a propósito — es la técnica de acceso/debug que funciona **igual en cualquier clúster de Kubernetes**, incluido EKS en la Fase 10. Aprender el atajo "mágico" de Docker Desktop no se transfiere; aprender `port-forward` sí.

## Pasos ejecutados

```bash
# Rama de trabajo
git checkout -b feature/fase-4-k8s-local

# Confirmar que el clúster local está arriba
kubectl config get-contexts
kubectl cluster-info
kubectl get nodes -o wide

# Reconstruir la imagen local (Fase 1) — Docker Desktop la deja visible para el clúster
docker build -t monolitomod-api:local .

# Aplicar manifiestos (namespace primero, para que exista antes que los recursos que lo referencian)
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml

# Verificar estado
kubectl get pods -n monolitomod -o wide
kubectl get deployment,svc -n monolitomod

# Exponer el Service en el host y validar el mismo flujo de siempre
kubectl port-forward -n monolitomod svc/monolitomod-api 5052:80 &
curl -s http://localhost:5052/health
curl -s -X POST http://localhost:5052/api/purchases -H "Content-Type: application/json" \
  -d '{"customerEmail":"buyer@example.com","items":[{"productId":"book","quantity":2}]}' -i
```

## Hallazgo real durante la validación: `port-forward` NO balancea carga

Se esperaba que, al pegarle varias veces a `svc/monolitomod-api` vía `port-forward`, el tráfico se repartiera entre los 2 pods (así funciona un Service "de verdad" dentro del clúster). Se comprobó con evidencia de logs que **no es así**:

```bash
# Requests que llegaron por nuestro port-forward (identificables por el host "localhost:5052" en el log)
kubectl logs -n monolitomod pod/monolitomod-api-ff9c8d46b-xkm6p | grep -c "localhost:5052"   # -> 16
kubectl logs -n monolitomod pod/monolitomod-api-ff9c8d46b-zppt5 | grep -c "localhost:5052"   # -> 0

# Tráfico que SÍ llegó al segundo pod, pero es el kubelet haciendo sus propias probes
# directo a la IP del pod (no pasa por el Service)
kubectl logs -n monolitomod pod/monolitomod-api-ff9c8d46b-zppt5 | grep -c "10.1.0.10:8080/health"  # -> 106
```

Las 16 requests de prueba fueron **todas** al mismo pod (`xkm6p`); el otro (`zppt5`) solo registró las probes del kubelet dirigidas directamente a su IP, no tráfico nuestro. Conclusión verificada: `kubectl port-forward` contra un Service resuelve **un** pod al iniciar la sesión y queda fijo a él durante toda la conexión — no es el mismo mecanismo de balanceo (iptables/IPVS de kube-proxy) que sí actúa sobre tráfico real generado *dentro* del clúster. Para observar balanceo real habría que generar tráfico desde otro pod (`kubectl run` + `curl` contra el ClusterIP) en vez de vía `port-forward`.

## Archivos creados/modificados

- `k8s/namespace.yaml`
- `k8s/deployment.yaml` — 2 réplicas, resources, readiness/liveness probes
- `k8s/service.yaml` — ClusterIP

## Verificación (reproducible)

```bash
docker build -t monolitomod-api:local .
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl get pods -n monolitomod        # ambos 1/1 Running
kubectl port-forward -n monolitomod svc/monolitomod-api 5052:80
# en otra terminal: curl http://localhost:5052/health
```

## Pendientes / notas para la siguiente fase

- [ ] **Fase 10 (EKS)**: estos mismos manifiestos son la base a adaptar — cambia principalmente `image` (pasa a apuntar a ECR) e `imagePullPolicy` (vuelve a `IfNotPresent`/default), y el Service probablemente necesite un Ingress con el AWS Load Balancer Controller en vez de solo `ClusterIP`.
- [ ] **Fase 12 (HPA)**: ya están los `resources.requests` necesarios; falta el recurso `HorizontalPodAutoscaler` en sí.
- [ ] Limpieza local (no se ejecuta ahora, queda desplegado para poder mostrarlo): `kubectl delete namespace monolitomod` elimina todo lo de esta fase de una vez.
