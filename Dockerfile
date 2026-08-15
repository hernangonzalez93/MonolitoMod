# Etapa 1 — build: usa el SDK completo (pesado, ~800MB) solo para compilar/publicar.
# Esta imagen nunca llega a producción, se descarta al final.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# --- Paso 1: copiar SOLO lo necesario para "dotnet restore" ---
# Directory.Build.props define TargetFramework/Nullable/etc para TODOS los proyectos
# (ningún .csproj individual lo declara), así que debe copiarse con la misma
# estructura relativa o MSBuild no lo va a encontrar al subir por el árbol de carpetas.
COPY Directory.Build.props global.json MonolitoMod.slnx ./

# Se copian únicamente los .csproj (no el código .cs todavía). Esto es a propósito:
# Docker cachea cada instrucción por capas. Mientras estos .csproj no cambien,
# "dotnet restore" (el paso más lento, descarga paquetes NuGet) se sirve desde caché
# incluso si después cambiamos un archivo .cs cualquiera.
COPY src/MonolitoMod.Api/MonolitoMod.Api.csproj src/MonolitoMod.Api/
COPY src/MonolitoMod.Contracts/MonolitoMod.Contracts.csproj src/MonolitoMod.Contracts/
COPY src/MonolitoMod.EventBus/MonolitoMod.EventBus.csproj src/MonolitoMod.EventBus/
COPY src/Modules/Inventory/MonolitoMod.Inventory/MonolitoMod.Inventory.csproj src/Modules/Inventory/MonolitoMod.Inventory/
COPY src/Modules/Notifications/MonolitoMod.Notifications/MonolitoMod.Notifications.csproj src/Modules/Notifications/MonolitoMod.Notifications/

RUN dotnet restore src/MonolitoMod.Api/MonolitoMod.Api.csproj

# --- Paso 2: ahora sí, copiar todo el código fuente y compilar ---
# A partir de aquí la caché de capas ya no ayuda tanto (el código cambia seguido),
# pero el restore de arriba seguirá reutilizándose mientras las dependencias no cambien.
COPY src/ src/

RUN dotnet publish src/MonolitoMod.Api/MonolitoMod.Api.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

# Etapa 2 — final: imagen runtime, sin SDK, sin código fuente, mucho más liviana (~200MB).
# Es lo único que termina en el registry y en producción.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

# La imagen base ya expone el puerto 8080 y define ASPNETCORE_HTTP_PORTS=8080
# por defecto desde .NET 8 en adelante; se deja explícito aquí para que quede
# documentado y no dependa de un comportamiento implícito de la imagen base.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# $APP_UID es una variable que la propia imagen base de Microsoft define,
# apuntando a un usuario sin privilegios (no root) creado en la imagen.
# Ejecutar como no-root es una práctica de seguridad estándar en contenedores:
# si el proceso es comprometido, no tiene privilegios de administrador dentro del contenedor.
USER $APP_UID

COPY --from=build /app/publish .

ENTRYPOINT ["dotnet", "MonolitoMod.Api.dll"]
