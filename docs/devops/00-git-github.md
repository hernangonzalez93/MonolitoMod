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

## Pendiente / próximo paso

- [ ] Autenticar GitHub CLI: `gh auth login` (requiere interacción del usuario en navegador — no se puede automatizar).
- [ ] Decidir nombre y visibilidad del repositorio en GitHub.
- [ ] `gh repo create` + `git push`.
- [ ] Branch protection sobre `main`: al menos "require PR before merging" desde ahora; "require status checks" se añade en la Fase 2, una vez exista el workflow de CI.
