using MonolitoMod.Contracts.Purchases;
using MonolitoMod.EventBus.Abstractions;
using MonolitoMod.EventBus.DependencyInjection;
using MonolitoMod.Inventory.DependencyInjection;
using MonolitoMod.Notifications.DependencyInjection;
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddInMemoryEventBus();
builder.Services.AddInventoryModule();
builder.Services.AddNotificationsModule();
var app = builder.Build();
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));
app.MapPost("/api/purchases", async (CreatePurchaseRequest request, IEventBus bus, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.CustomerEmail) || request.Items.Count == 0 || request.Items.Any(i => string.IsNullOrWhiteSpace(i.ProductId) || i.Quantity <= 0)) return Results.ValidationProblem(new Dictionary<string, string[]> { ["purchase"] = ["CustomerEmail and at least one valid item are required."] });
    var id = Guid.NewGuid();
    await bus.PublishAsync(new PurchaseCreatedEvent(id, request.CustomerEmail, request.Items.Select(i => new PurchaseCreatedItem(i.ProductId, i.Quantity)).ToArray(), DateTimeOffset.UtcNow), ct);
    return Results.Accepted($"/api/purchases/{id}", new { purchaseId = id });
});
app.Run();
public sealed record CreatePurchaseRequest(string CustomerEmail, IReadOnlyCollection<PurchaseItemRequest> Items);
public sealed record PurchaseItemRequest(string ProductId, int Quantity);
public partial class Program;
