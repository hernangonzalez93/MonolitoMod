# Fase 2 — CI en GitHub Actions + seguridad

## Objetivo

Automatizar build + test en cada Pull Request, y agregar tres capas de seguridad al pipeline: escaneo de vulnerabilidades de la imagen (Trivy), análisis estático del código C# (CodeQL), y actualización automática de dependencias desactualizadas (Dependabot).

## Contexto/decisiones

### Dos jobs separados: `build-test` y `docker-scan`

`docker-scan` depende de `build-test` (`needs: build-test`) — no tiene sentido construir y escanear una imagen si el código ni siquiera compila o pasa los tests. Mantenerlos separados (en vez de un solo job largo) también deja más claro en la UI de GitHub *qué* falló cuando algo falla.

### Trivy: dos pasadas con propósitos distintos

1. **Pasada de reporte** (`format: sarif`, `exit-code: "0"`): escanea CRITICAL+HIGH, sube el resultado al tab de *Security > Code scanning* de GitHub vía `github/codeql-action/upload-sarif`, pero **no falla el build**. Sirve como historial/visibilidad de todo lo que se encuentra, incluso lo que no bloquea.
2. **Pasada de gate** (`format: table`, `exit-code: "1"`): solo mira CRITICAL. Esta es la que realmente puede tumbar el pipeline.

Se limitó el gate a CRITICAL (no HIGH) para no bloquear el aprendizaje por CVEs de la imagen base que quizás no tengan solución inmediata disponible. Además, ambas pasadas usan `ignore-unfixed: true`: ignora vulnerabilidades para las que **todavía no existe un parche** — no tiene sentido bloquear un build por algo que no se puede arreglar hoy.

*Nota honesta*: este umbral (solo CRITICAL, con fix disponible) es un punto de partida razonable, no una verdad absoluta. Si en un futuro aparecen HIGH relevantes que sí convenga bloquear, se ajusta el `severity` de la segunda pasada.

### CodeQL — activado como "default setup"

A diferencia de Trivy (que corre como un paso dentro de nuestro `ci.yml`), CodeQL se activó como **configuración del repositorio** (GitHub-managed), vía:

```bash
gh api -X PATCH repos/hernangonzalez93/MonolitoMod/code-scanning/default-setup \
  --input - <<'EOF'
{ "state": "configured", "query_suite": "default", "languages": ["csharp"] }
EOF
```

Esto es intencional: no vive como archivo en `.github/workflows/`, GitHub lo administra y actualiza las queries automáticamente. Gratis para repos públicos. Analiza el código en busca de patrones de vulnerabilidad (inyección, deserialización insegura, etc.) — complementa a Trivy, que solo mira el sistema operativo/paquetes de la imagen, no la lógica del código.

### Dependabot: tres ecosistemas, no solo NuGet

`.github/dependabot.yml` vigila:
- **`nuget`** → paquetes del proyecto .NET
- **`github-actions`** → versiones de las Actions usadas en los workflows (relevante por el error real documentado abajo)
- **`docker`** → las imágenes base del `Dockerfile` (`mcr.microsoft.com/dotnet/sdk:10.0` / `aspnet:10.0`) — cierra el círculo con Trivy: si Trivy encuentra una CVE en la imagen base, lo más probable es que Dependabot ya haya abierto (o vaya a abrir) el PR que la resuelve.

### `global-json-file` en `setup-dotnet`

En vez de hardcodear la versión del SDK en el workflow (duplicando lo que ya dice `global.json`), se usó:
```yaml
- uses: actions/setup-dotnet@v4
  with:
    global-json-file: global.json
```
Una sola fuente de verdad para la versión del SDK — si se actualiza `global.json`, el CI la sigue automáticamente.

## Incidente real durante esta fase (vale la pena documentarlo)

El primer push falló casi instantáneamente en `docker-scan`, **antes** de llegar a construir la imagen:

```
##[error]Unable to resolve action `aquasecurity/trivy-action@0.24.0`, unable to find version `0.24.0`
```

El tag `0.24.0` se escribió de memoria y estaba mal en dos sentidos: le faltaba el prefijo `v` (los tags reales son `v0.24.0`, `v0.36.0`, etc.) y de todas formas no era la versión más reciente. **Antes de corregir a ciegas**, se verificaron los tags reales contra la API de GitHub:

```bash
gh api repos/aquasecurity/trivy-action/tags --paginate -q '.[].name'
# v0.36.0, v0.35.0, v0.34.0, ...
```

Se repineó a `aquasecurity/trivy-action@v0.36.0` (el más reciente en ese momento), y de paso se verificaron con el mismo método los otros tags usados en el workflow (`actions/checkout@v4`, `actions/setup-dotnet@v4`, `github/codeql-action@v3`) para no repetir el mismo error.

**Lección para las fases siguientes**: nunca confiar de memoria en un tag/versión de una Action de terceros — verificar contra `gh api repos/<owner>/<repo>/tags` antes de pinearla. Como además `github-actions` ya está en `dependabot.yml`, aunque esto vuelva a quedar desactualizado en el futuro, Dependabot va a abrir un PR proponiendo el bump automáticamente.

## Pasos ejecutados

```bash
# Rama de trabajo
git checkout -b feature/fase-2-ci-security

# Activar CodeQL (config de repo, fuera del PR)
gh api -X PATCH repos/hernangonzalez93/MonolitoMod/code-scanning/default-setup --input - <<'EOF'
{ "state": "configured", "query_suite": "default", "languages": ["csharp"] }
EOF

# Commit + push + PR (ver .github/workflows/ci.yml y .github/dependabot.yml)
git add .github/
git commit -m "ci: add GitHub Actions build/test pipeline with Trivy image scanning"
git push -u origin feature/fase-2-ci-security
gh pr create --title "ci: add GitHub Actions pipeline + security scanning (Fase 2)" --body "..."

# Observar los checks corriendo por primera vez en el PR
gh pr checks 3 --watch --interval 15

# (fix del tag de Trivy, commit adicional en la misma rama, push, re-watch)

# Una vez todos los checks en verde, confirmar los nombres EXACTOS de contexto
# antes de exigirlos en branch protection (no asumir el formato)
HEAD_SHA=$(gh pr view 3 --json headRefOid -q .headRefOid)
gh api repos/hernangonzalez93/MonolitoMod/commits/$HEAD_SHA/check-runs \
  -q '.check_runs[] | "\(.name) -> \(.conclusion)"'
# Trivy -> success | CodeQL -> success | docker-scan -> success
# build-test -> success | Analyze (csharp) -> success

# Actualizar branch protection: exigir los 3 checks que realmente actúan como gate
# (se deja fuera "Trivy" y "Analyze (csharp)", que son sub-checks/duplicados de
# "docker-scan" y "CodeQL" respectivamente)
gh api -X PUT repos/hernangonzalez93/MonolitoMod/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["build-test", "docker-scan", "CodeQL"] },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false
  },
  "restrictions": null
}
EOF
```

## Archivos creados/modificados

- `.github/workflows/ci.yml` — jobs `build-test` y `docker-scan`.
- `.github/dependabot.yml` — nuget + github-actions + docker, semanal.
- (fuera del repo) configuración de code scanning default setup para CodeQL.
- (fuera del repo) branch protection de `main`, actualizada con `required_status_checks`.

## Verificación

```bash
gh pr checks <PR>                 # todos los checks en verde antes de mergear
gh api repos/hernangonzalez93/MonolitoMod/branches/main/protection \
  -q '.required_status_checks.contexts'
```

## Resultado final de esta fase

- `main` ahora exige, para poder mergear un PR: `build-test`, `docker-scan` y `CodeQL` en verde, además de estar actualizada respecto a `main` (`strict: true`).
- Cualquier CVE CRITICAL con fix disponible en la imagen bloquea el merge automáticamente.
- Todo lo demás (HIGH, CVEs sin fix, hallazgos de CodeQL de severidad menor) queda visible en el tab de Security sin bloquear, para no frenar el desarrollo por hallazgos que no se pueden resolver de inmediato.
- Dependabot va a empezar a abrir PRs semanales por paquetes/actions/imagen base desactualizados.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 3**: la imagen ya se construye y escanea en CI (`docker build -t monolitomod-api:ci .`); ahí se le va a agregar tag + push a `ghcr.io`, reutilizando el mismo `Dockerfile`.
- [ ] Revisar periódicamente los PRs que abra Dependabot — no van a mergearse solos (a propósito, para revisar cada bump).
