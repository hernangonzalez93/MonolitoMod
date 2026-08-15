# Fase 1 — Contenerizar la API

## Objetivo

Empaquetar `MonolitoMod.Api` como imagen Docker, lista para correr en cualquier lado (local, Kubernetes, ECS/Fargate, EKS) sin depender del SDK de .NET instalado en el host.

## Contexto/decisiones

### Por qué multi-stage build

Una imagen Docker "ingenua" incluiría el SDK completo (compilador, herramientas de build, ~800MB+) dentro de la imagen final que corre en producción — pesada y con superficie de ataque innecesaria (herramientas que nadie necesita en runtime).

La solución estándar es un **build multi-stage**:
- **Etapa `build`**: parte de `mcr.microsoft.com/dotnet/sdk:10.0`, compila y publica el proyecto.
- **Etapa `final`**: parte de `mcr.microsoft.com/dotnet/aspnet:10.0` (solo el runtime de ASP.NET, sin SDK), y copia *únicamente* la carpeta `/app/publish` generada por la etapa anterior con `COPY --from=build`.

Docker descarta todas las capas intermedias de la etapa `build` en la imagen final — el SDK nunca viaja a producción. Resultado medido: **230MB** la imagen final.

### Por qué el orden de los `COPY` importa (cacheo de capas)

Docker cachea cada instrucción del Dockerfile como una capa. Si el contenido copiado en un `COPY` no cambió respecto al build anterior, Docker reutiliza el resultado en caché de esa capa **y de todas las siguientes**, sin volver a ejecutarlas.

`dotnet restore` (descargar paquetes NuGet) es el paso más lento del build. Por eso:
1. Primero se copian *solo* los archivos `.csproj` (que declaran las dependencias) más `Directory.Build.props`/`global.json`/`MonolitoMod.slnx`.
2. Se corre `dotnet restore`.
3. **Después** se copia el resto del código fuente (`COPY src/ src/`) y se compila.

Mientras no cambien las dependencias de ningún proyecto (los `.csproj`), el restore se sirve desde caché aunque se modifique cualquier archivo `.cs` — acelera muchísimo las reconstrucciones durante desarrollo iterativo, y será clave en la Fase 2 para que el job de CI no tarde minutos en cada build.

### Por qué `Directory.Build.props` se copia explícitamente

Ningún `.csproj` del proyecto declara `<TargetFramework>` — esa propiedad (junto con `Nullable`, `ImplicitUsings`, `TreatWarningsAsErrors`) vive en `Directory.Build.props` en la raíz del repo. MSBuild la encuentra subiendo por el árbol de directorios desde cada `.csproj` hasta la raíz. Si ese archivo no se copia con la misma estructura relativa dentro de la imagen, el build fallaría (o compilaría con defaults incorrectos).

### `.dockerignore`

Al inspeccionar el disco antes de escribir el Dockerfile se encontraron carpetas `bin/` y `obj/` ya generadas por builds previos en Visual Studio (Git las ignora, pero **Docker no**: el build usa el estado real del disco, no lo que está en Git). Sin excluirlas, `COPY src/ src/` habría copiado binarios compilados en Windows y metadata de restore obsoleta dentro del contexto de build de Linux — en el mejor caso, basura innecesaria; en el peor, conflictos raros de restore. `.dockerignore` excluye `**/bin/`, `**/obj/`, `.git/`, `tests/`, `docs/`, etc. También reduce el tamaño del contexto que Docker envía al daemon en cada build.

### Usuario no root

La imagen base `aspnet:10.0` de Microsoft ya define un usuario sin privilegios (expuesto como la variable de entorno `$APP_UID`, apunta a UID 1654 en esta imagen). Se agregó `USER $APP_UID` antes del `ENTRYPOINT` para que el proceso corra sin privilegios de root dentro del contenedor — si el proceso fuera comprometido, no tiene permisos administrativos en el sistema de archivos del contenedor. Verificado con `docker exec ... whoami` → `app`.

### Puerto 8080

Desde .NET 8, las imágenes oficiales de ASP.NET Core escuchan en el puerto 8080 por defecto (variable `ASPNETCORE_HTTP_PORTS`). Se dejó `ENV ASPNETCORE_HTTP_PORTS=8080` y `EXPOSE 8080` de forma explícita en el Dockerfile aunque ya sería el comportamiento por defecto de la imagen base — preferible no depender de un default implícito sin documentarlo.

## Pasos ejecutados

```bash
# Build de la imagen (multi-stage, definido en ./Dockerfile)
docker build -t monolitomod-api:local .

# Levantar un contenedor de prueba, mapeando 5050 (host) -> 8080 (contenedor)
docker run -d --rm --name monolitomod-test -p 5050:8080 monolitomod-api:local

# Validar el mismo flujo que se probaba en local sin Docker (ver README.md)
curl -s http://localhost:5050/health
curl -s -X POST http://localhost:5050/api/purchases \
  -H "Content-Type: application/json" \
  -d '{"customerEmail":"buyer@example.com","items":[{"productId":"book","quantity":2},{"productId":"pen","quantity":1}]}' \
  -i

# Confirmar usuario no-root
docker exec monolitomod-test whoami   # -> app
docker exec monolitomod-test id       # -> uid=1654(app) gid=1654(app)

# Limpieza
docker stop monolitomod-test
```

## Resultados obtenidos

- `GET /health` → `200 OK`, `{"status":"healthy"}`
- `POST /api/purchases` → `202 Accepted`, `{"purchaseId":"..."}`
- Usuario del proceso: `app` (uid 1654), no root
- Tamaño de la imagen final: **230MB**

## Archivos creados/modificados

- `Dockerfile` — build multi-stage (SDK → runtime), en la raíz del repo.
- `.dockerignore` — excluye `bin/`, `obj/`, `.git/`, `tests/`, `docs/`, resultados de test.

## Verificación (reproducible)

```bash
docker build -t monolitomod-api:local .
docker run --rm -p 5050:8080 monolitomod-api:local
# en otra terminal:
curl http://localhost:5050/health
```

## Pendientes / notas para la siguiente fase

- [ ] **Fase 2**: el job de CI debe correr `dotnet test` (no solo `dotnet publish`) antes de construir la imagen — la Fase 1 no ejecutó los tests automáticamente, solo se validó manualmente contra el contenedor corriendo.
- [ ] **Fase 2**: agregar un paso de escaneo de la imagen (Trivy) sobre `monolitomod-api:local` como parte del pipeline.
- [ ] **Fase 3**: esta misma imagen es la que se va a etiquetar y publicar en `ghcr.io`.
