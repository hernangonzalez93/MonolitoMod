# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Educational .NET 10 example of a **modular monolith** simulating a purchase flow with no persistence, no retries, and no external bus library. `POST /api/purchases` validates the purchase and publishes `PurchaseCreatedEvent`. The custom in-memory bus delivers it to two independent handlers: Inventory records a per-item adjustment, Notifications records a customer confirmation. The API only publishes the contract — it never calls the modules directly, and the modules never reference each other. API project references exist solely to wire up DI at startup.

## Commands

Requires .NET 10 SDK (pinned via `global.json`, `10.0.302`). Run from the repo root.

```powershell
dotnet restore
dotnet build MonolitoMod.slnx
dotnet test MonolitoMod.slnx
```

Run a single test project:

```powershell
dotnet test tests/MonolitoMod.Inventory.UnitTests/MonolitoMod.Inventory.UnitTests.csproj
```

Run a single test by name (any project):

```powershell
dotnet test --filter "FullyQualifiedName~Purchase_reaches_both_modules"
```

Run the API locally end-to-end:

```powershell
dotnet run --project src/MonolitoMod.Api --urls http://localhost:5050
```

```powershell
Invoke-RestMethod http://localhost:5050/health
$body = @{ customerEmail = 'buyer@example.com'; items = @(@{ productId = 'book'; quantity = 2 }, @{ productId = 'pen'; quantity = 1 }) } | ConvertTo-Json -Depth 3
Invoke-WebRequest http://localhost:5050/api/purchases -Method Post -ContentType 'application/json' -Body $body
```

Expect `202 Accepted` with a `purchaseId`. All effects live in memory for the lifetime of the process.

## Architecture

**Project dependency graph** (strict, no cycles):

```
EventBus  <-- Contracts  <-- Inventory, Notifications  <-- Api
```

- `MonolitoMod.EventBus` — bus abstractions (`IEventBus`, `IIntegrationEvent`, `IIntegrationEventHandler<T>`) plus the single implementation `InMemoryEventBus`. `PublishAsync` creates a DI scope via `IServiceScopeFactory` and awaits every registered `IIntegrationEventHandler<TEvent>` in turn — no queueing, no retry, no persistence.
- `MonolitoMod.Contracts` — shared integration events only (e.g. `PurchaseCreatedEvent`). This is the sole coupling surface between modules; modules never reference each other's projects.
- `src/Modules/<Name>/MonolitoMod.<Name>/` — one project per module (`Inventory`, `Notifications`). Each is a self-contained mini clean-architecture slice:
  - `Domain/` — module-local entities (e.g. `InventoryAdjustment`)
  - `Application/` — ports (e.g. `IInventoryActivityStore`) and event handlers, namespaced by event under `Application/<EventName>/` (e.g. `Application/PurchaseCreated/AdjustInventoryOnPurchaseCreatedHandler`)
  - `Infrastructure/` — in-memory implementations of the ports
  - `DependencyInjection/` — one `IServiceCollection` extension method (`AddInventoryModule()`, `AddNotificationsModule()`) that registers the module's store and handler
  - Note: `Inventory` splits these into separate files; `Notifications` collapses the same layers into a single `Notifications.cs` using nested namespaces. Follow whichever style matches the module you're editing.
- `MonolitoMod.Api` — minimal API host. `Program.cs` composes the app by calling each module's `Add*Module()` extension and `AddInMemoryEventBus()`, then only ever talks to `IEventBus.PublishAsync`. It has no knowledge of module internals beyond registration. `public partial class Program;` is declared at the bottom to support `WebApplicationFactory<Program>` in integration tests.

**Adding a new integration event / module reaction:**
1. Define the event record in `MonolitoMod.Contracts` (implements `IIntegrationEvent`).
2. In the reacting module, add a handler under `Application/<EventName>/` implementing `IIntegrationEventHandler<TEvent>`.
3. Register the handler in that module's `DependencyInjection` extension.
4. Publish the event from wherever it originates via `IEventBus.PublishAsync`.

**Tests** mirror this structure 1:1: one unit-test project per module (constructs handlers directly against in-memory stores) plus one integration-test project that boots the full API via `WebApplicationFactory<Program>`, posts a purchase over HTTP, and asserts both modules' stores received the effect.

`Directory.Build.props` sets `TreatWarningsAsErrors` for the whole solution — builds fail on warnings, not just errors.
