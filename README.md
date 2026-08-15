# Monolito modular orientado a eventos

Ejemplo educativo en .NET 10 que simula una compra sin persistencia, reintentos ni librerías externas para el bus.

## Funcionamiento

`POST /api/purchases` valida la compra y publica `PurchaseCreatedEvent`. El bus propio, en memoria, entrega el contrato a dos manejadores: Inventory registra un ajuste por artículo y Notifications registra una confirmación para el cliente. La API publica el contrato y no invoca los módulos; los módulos tampoco se referencian entre sí. Las referencias desde API solo componen las dependencias al arrancar.

Cada módulo separa dominio, aplicación (puertos y manejadores), infraestructura en memoria y el registro de dependencias. Contratos y bus son proyectos separados.

## Compilar y probar

Requiere el SDK .NET 10. Desde la raíz:

```powershell
dotnet restore
dotnet build MonolitoMod.slnx
dotnet test MonolitoMod.slnx
```

Hay dos pruebas unitarias y una prueba de integración. La integración inicia la API, envía una compra HTTP y confirma que ambos módulos procesaron el evento.

## Prueba end-to-end local

En una consola:

```powershell
dotnet run --project src/MonolitoMod.Api --urls http://localhost:5050
```

En otra:

```powershell
Invoke-RestMethod http://localhost:5050/health
$body = @{ customerEmail = 'buyer@example.com'; items = @(@{ productId = 'book'; quantity = 2 }, @{ productId = 'pen'; quantity = 1 }) } | ConvertTo-Json -Depth 3
Invoke-WebRequest http://localhost:5050/api/purchases -Method Post -ContentType 'application/json' -Body $body
```

Debe devolver `202 Accepted` con un `purchaseId`. Los efectos se conservan en memoria mientras se ejecuta el proceso.
