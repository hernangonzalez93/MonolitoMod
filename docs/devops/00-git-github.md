# Fase 0 — Git & GitHub

## Objetivo

Convertir la carpeta local del proyecto en un repositorio Git versionado y publicarlo en GitHub, dejando una base limpia (sin ruido de artefactos de build) sobre la cual construir CI/CD en las fases siguientes.

## Contexto/decisiones

- El proyecto no tenía `.git` — se creó desde cero con `git init` (no se clonó desde ningún lado).
- `.gitignore`: se creó a mano en vez de usar el generador de GitHub, cubriendo específicamente lo que este proyecto puede producir:
  - `bin/`, `obj/`, `out/` → artefactos de compilación .NET (se regeneran con `dotnet build`, nunca deben versionarse).
  - `.vs/` → carpeta de estado local de Visual Studio (ya existía en el directorio antes de este commit).
  - Entradas para Rider/VS Code, resultados de tests (`TestResults/`, `*.trx`), y paquetes NuGet.
  - **Se adelantaron entradas para Terraform** (`*.tfstate`, `.terraform/`) y variables de entorno (`*.env`) aunque todavía no existen esos archivos — evita tener que acordarse de añadirlas en la Fase 6 y previene que un `terraform apply` accidental suba estado (que puede contener datos sensibles de infraestructura) al repo.
- Antes de hacer `git add -A` se revisó `git status` para confirmar que no se colaba nada sensible (se inspeccionó `launchSettings.json`, que solo tiene puertos de desarrollo local, sin secretos).
- El branch por defecto quedó como `master` (nombre que usa `git init` en esta instalación de Git). *Nota: cuando se cree el repo en GitHub, se puede renombrar a `main` para seguir la convención estándar — GitHub lo crea como `main` por defecto en repos nuevos.*

## Pasos ejecutados

```bash
# 1. Crear .gitignore (ver archivo .gitignore en la raíz del repo)

# 2. Inicializar el repositorio
git init

# 3. Revisar qué se va a versionar antes de comprometerse
git add -A
git status

# 4. Primer commit
git commit -m "Initial commit: modular monolith skeleton (Api, Contracts, EventBus, Inventory, Notifications modules)"
```

Resultado: commit raíz `f85caec`, 32 archivos, 333 líneas.

## Archivos creados/modificados

- `.gitignore` — reglas de exclusión para .NET, IDEs, tests, y (adelantado) Terraform/env files.
- `.git/` — repositorio local (no versionado, es la carpeta interna de Git).

## Verificación

```bash
git log --oneline
git status   # debe mostrar "nothing to commit, working tree clean"
```

## Parte 2 — Publicación en GitHub y branch protection

### Decisiones

- **Repositorio**: `hernangonzalez93/MonolitoMod`, público. Repo de portafolio de este estudio de CI/CD.
- **Autenticación**: `gh auth login` es un flujo OAuth interactivo por navegador — lo ejecutó el usuario directamente, no algo automatizable por el asistente. Se verificó con `gh auth status` (cuenta `hernangonzalez93`, scopes `repo`, `workflow`, `read:org`, `gist` — el scope `workflow` es imprescindible para más adelante, cuando se empiecen a versionar archivos en `.github/workflows/`, GitHub lo exige explícitamente).
- **Rama por defecto**: se renombró `master` → `main` localmente *antes* de crear el repo remoto, para que quedara publicada directamente como `main` (evita un paso extra de renombrar en GitHub después).
- **Branch protection sobre `main`**: se activó vía API (`gh api`) en vez de la UI web, para que quedara reproducible y documentado como comando. Configuración elegida:
  - `required_pull_request_reviews.required_approving_review_count: 0` → obliga a que todo cambio llegue por Pull Request (no se puede hacer `git push` directo a `main`), pero **no exige que alguien más apruebe** el PR. Esto es intencional: siendo el único colaborador, exigir 1 aprobación bloquearía cualquier merge (GitHub no permite auto-aprobar tu propio PR). El valor `0` sí es aceptado por la API — se confirmó empíricamente con la llamada real, sin asumirlo de memoria.
  - `required_status_checks: null` → todavía no hay CI, así que no hay checks que exigir. **Se debe revisar y actualizar esta fase cuando exista el workflow de la Fase 2**, añadiendo el job de build/test como check obligatorio.
  - `enforce_admins: false` → como dueño del repo, el usuario puede seguir haciendo bypass manual si hace falta (por ejemplo, un hotfix urgente). Se puede endurecer más adelante.
  - `allow_force_pushes: false`, `allow_deletions: false` → quedan bloqueados por defecto al activar protección, sin configurarlo explícitamente.

### Comandos ejecutados

```bash
# Verificar autenticación
gh auth status

# Renombrar la rama local antes de publicar
git branch -m master main

# Crear el repo en GitHub, configurar el remoto 'origin' y hacer push en un solo paso
gh repo create MonolitoMod --public --source=. --remote=origin --push

# Activar branch protection sobre main (PR obligatorio, sin aprobaciones mínimas)
gh api -X PUT repos/hernangonzalez93/MonolitoMod/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": null,
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

### Verificación

```bash
gh repo view hernangonzalez93/MonolitoMod --web   # abre el repo en el navegador
gh api repos/hernangonzalez93/MonolitoMod/branches/main/protection   # confirma la config activa
```

Resultado esperado: `git push origin main` directo (sin PR) debe ser rechazado por GitHub a partir de este punto; los cambios deben llegar vía rama + Pull Request.

## Pendientes / notas para la siguiente fase

- [ ] **Fase 2**: cuando exista el workflow de CI, volver a esta configuración de branch protection y añadir el job correspondiente en `required_status_checks.contexts`, para que un PR no se pueda mergear si el build/test falla.
- [ ] A partir de ahora, todo cambio (incluyendo el Dockerfile de la Fase 1) debe hacerse en una rama feature + PR, no directo a `main` — es el flujo que la protección ya está forzando.
