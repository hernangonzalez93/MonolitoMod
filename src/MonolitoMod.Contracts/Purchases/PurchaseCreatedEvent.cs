using MonolitoMod.EventBus.Abstractions;

namespace MonolitoMod.Contracts.Purchases;

public sealed record PurchaseCreatedEvent(
    Guid PurchaseId,
    string CustomerEmail,
    IReadOnlyCollection<PurchaseCreatedItem> Items,
    DateTimeOffset OccurredOnUtc) : IIntegrationEvent;

public sealed record PurchaseCreatedItem(string ProductId, int Quantity);
