using MonolitoMod.Contracts.Purchases;
using MonolitoMod.EventBus.Abstractions;
using MonolitoMod.Inventory.Domain;
namespace MonolitoMod.Inventory.Application.PurchaseCreated;
public sealed class AdjustInventoryOnPurchaseCreatedHandler(IInventoryActivityStore store) : IIntegrationEventHandler<PurchaseCreatedEvent>
{ public Task HandleAsync(PurchaseCreatedEvent @event, CancellationToken cancellationToken) { foreach (var item in @event.Items) store.Record(new InventoryAdjustment(@event.PurchaseId, item.ProductId, item.Quantity)); return Task.CompletedTask; } }
