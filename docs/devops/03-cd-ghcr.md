# Fase 3 — CD ligero a GitHub Container Registry

## Objetivo

Publicar automáticamente la imagen Docker en un registry cada vez que se mergea a `main`, usando GitHub Container Registry (GHCR) — sin secretos que crear ni cuentas externas, como paso intermedio antes de publicar en AWS ECR en la Fase 6.

## Contexto/decisiones

### Un job nuevo dentro del mismo `ci.yml`, no un workflow separado

Se agregó `publish-ghcr` como tercer job del mismo workflow (renombrado de `CI` a `CI/CD` para reflejarlo), en vez de crear `cd.yml` aparte. Para el tamaño actual del pipeline, tener todo en un solo archivo es más fácil de seguir. Es razonable separarlo más adelante (Fase 7, al desplegar a Fargate) si el archivo crece demasiado.

### Por qué NO se reconstruye la imagen en `publish-ghcr`

La alternativa obvia sería que `publish-ghcr` corra su propio `docker build`. Se descartó a propósito: eso abriría una ventana entre "lo que escaneó Trivy" y "lo que se publica" — si la imagen base `mcr.microsoft.com/dotnet/aspnet:10.0` recibiera una actualización entre el build de `docker-scan` y un build nuevo en `publish-ghcr` (son jobs en runners distintos, minutos aparte), se podría estar publicando bits ligeramente distintos a los que pasaron el gate de seguridad. Es un principio real de supply-chain security: **"build once, promote the same artifact"**, no reconstruir en cada etapa.

En vez de eso:
1. `docker-scan` guarda la imagen ya construida y ya escaneada con `docker save -o monolitomod-api.tar`.
2. La sube como artifact de GitHub Actions (`actions/upload-artifact@v7`, retención de 1 día — no hace falta más, es solo el puente entre dos jobs de la misma corrida).
3. `publish-ghcr` la descarga (`actions/download-artifact@v8`) y la carga con `docker load` — son exactamente los mismos bytes, no una recompilación.

### Gates con `if:` en vez de un trigger separado

Tanto los pasos de guardar/subir el artifact (dentro de `docker-scan`) como el job completo `publish-ghcr` llevan la misma condición:
```yaml
if: github.event_name == 'push' && github.ref == 'refs/heads/main'
```
Así, en un Pull Request (evento `pull_request`), ni se genera el artifact ni corre el job de publicación — aparece como `skipping`, no como fallo, y no afecta a branch protection (no está en la lista de checks requeridos). Solo se publica una imagen "oficial" cuando el código ya está fusionado en `main`, nunca desde una rama en revisión.

### Autenticación: `GITHUB_TOKEN`, no un secreto nuevo

`GITHUB_TOKEN` es un token que GitHub genera automáticamente para cada ejecución del workflow y expira al terminar el job — no hay que crear ni guardar ningún Personal Access Token como secreto del repo. Solo hizo falta declarar `packages: write` en los `permissions:` del job (por defecto el token no tiene ese permiso).

### Tags de la imagen

Dos tags por publicación:
- `latest` → siempre apunta al build más reciente de `main`.
- `<sha corto>` (7 caracteres del commit) → permite referenciar una versión exacta más adelante (útil ya en la Fase 7, para desplegar una versión específica en vez de "lo último" a ciegas).

## Pasos ejecutados

```bash
# Rama de trabajo
git checkout -b feature/fase-3-cd-ghcr

# (edición de .github/workflows/ci.yml: nuevo job publish-ghcr + pasos de
# guardar/subir artifact en docker-scan — ver el archivo para el detalle)

git add .github/workflows/ci.yml
git commit -m "ci: publish image to GHCR on push to main"
git push -u origin feature/fase-3-cd-ghcr
gh pr create --title "ci: publish image to GHCR on merge to main (Fase 3)" --body "..."

# Se observó el PR: publish-ghcr en "skipping" (evento pull_request), resto en verde
gh pr checks 6 --watch --interval 15

gh pr merge 6 --merge --delete-branch

# Se ubicó y siguió la corrida real disparada por el push a main
gh run list --branch main --limit 3 --json databaseId,workflowName,event,status,conclusion,createdAt
gh run watch <run-id> --interval 15
```

### Validación real (no solo revisar que el job esté en verde)

```bash
# Verificar que el paquete existe en GHCR (requirió agregar el scope
# read:packages/write:packages al token de gh CLI, vía gh auth refresh —
# flujo interactivo por navegador, lo hizo el usuario)
gh api users/hernangonzalez93/packages/container/monolitomod-api/versions \
  -q '.[] | "tags=\(.metadata.container.tags) created=\(.created_at)"'
# tags=["ebcc7fc","latest"] created=2026-08-15T10:58:09Z

# Pull real de la imagen publicada (no la que quedó cacheada localmente del build)
gh auth token | docker login ghcr.io -u hernangonzalez93 --password-stdin
docker pull ghcr.io/hernangonzalez93/monolitomod-api:latest

# Mismo smoke test de siempre, ahora contra la imagen bajada del registry
docker run -d --rm --name monolitomod-ghcr-test -p 5051:8080 ghcr.io/hernangonzalez93/monolitomod-api:latest
curl -s http://localhost:5051/health                      # -> {"status":"healthy"}
curl -s -X POST http://localhost:5051/api/purchases -i ... # -> 202 Accepted
docker stop monolitomod-ghcr-test
```

## Archivos creados/modificados

- `.github/workflows/ci.yml` — nuevo job `publish-ghcr`, pasos de artifact en `docker-scan`, rename del workflow a `CI/CD`.

## Resultado final de esta fase

- Cada merge a `main` publica automáticamente `ghcr.io/hernangonzalez93/monolitomod-api:latest` y `:<sha corto>`.
- La imagen publicada es *exactamente* la que pasó build, test y el gate de Trivy — no una reconstrucción.
- Se validó con un pull real desde el registry (no solo confiando en el log del job).
- El paquete quedó con visibilidad **privada** por defecto (comportamiento estándar de GHCR al publicar desde Actions) — suficiente para este estudio, ya que nadie más necesita tirar de esta imagen todavía.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 4**: usar esta misma imagen (o el `Dockerfile` local) para el despliegue en Kubernetes local con Docker Desktop.
- [ ] **Fase 6**: cuando se pase a AWS, el destino va a ser ECR en vez de GHCR — el patrón "build once, promote the same artifact" se puede reutilizar tal cual.
