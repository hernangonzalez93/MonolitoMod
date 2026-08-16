using System.Text.Json;
using Amazon.SQS;
using Amazon.SQS.Model;
using MonolitoMod.Contracts.Purchases;
using MonolitoMod.EventBus.Abstractions;
using MonolitoMod.EventBus.DependencyInjection;
using MonolitoMod.Inventory.DependencyInjection;
using MonolitoMod.Notifications.DependencyInjection;
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddInMemoryEventBus();
builder.Services.AddInventoryModule();
builder.Services.AddNotificationsModule();
// Fábrica, no instancia directa: "new AmazonSQSClient()" se ejecutaría de
// inmediato al registrar el singleton, incluso si nada lo llega a usar. En
// el host de test (PurchaseEndpointTests) IPurchaseEventPublisher se
// reemplaza por un fake, así que IAmazonSQS nunca se resuelve — pero con
// una instancia directa igual explotaría al arrancar, porque el SDK
// necesita región/credenciales para construirse. Con una fábrica, la
// construcción queda diferida hasta el primer uso real.
// En runtime resuelve credenciales vía el task role de ECS (Fase 11,
// terraform/fargate/iam.tf) y la región vía la variable de entorno
// AWS_REGION (seteada explícitamente en la task definition) — mismo
// mecanismo con el que ya veníamos autenticando aws/terraform localmente
// (Fase 5), solo que acá la identidad es la del task role, no un usuario IAM.
builder.Services.AddSingleton<IAmazonSQS>(_ => new AmazonSQSClient());
builder.Services.AddSingleton<IPurchaseEventPublisher, SqsPurchaseEventPublisher>();
var app = builder.Build();
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));
app.MapPost("/api/purchases", async (CreatePurchaseRequest request, IEventBus bus, IPurchaseEventPublisher publisher, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.CustomerEmail) || request.Items.Count == 0 || request.Items.Any(i => string.IsNullOrWhiteSpace(i.ProductId) || i.Quantity <= 0)) return Results.ValidationProblem(new Dictionary<string, string[]> { ["purchase"] = ["CustomerEmail and at least one valid item are required."] });
    var id = Guid.NewGuid();
    var purchaseEvent = new PurchaseCreatedEvent(id, request.CustomerEmail, request.Items.Select(i => new PurchaseCreatedItem(i.ProductId, i.Quantity)).ToArray(), DateTimeOffset.UtcNow);
    // Se suma como un consumidor más del mismo evento, sin reemplazar al bus
    // en memoria: Inventory y Notifications (Fase 0) siguen reaccionando
    // exactamente igual que antes, in-process. Esto es aparte: persiste la
    // compra de forma asíncrona vía SQS -> Lambda (Fase 12) -> RDS (Fase 10).
    await bus.PublishAsync(purchaseEvent, ct);
    await publisher.PublishAsync(purchaseEvent, ct);
    return Results.Accepted($"/api/purchases/{id}", new { purchaseId = id });
});
app.Run();
public sealed record CreatePurchaseRequest(string CustomerEmail, IReadOnlyCollection<PurchaseItemRequest> Items);
public sealed record PurchaseItemRequest(string ProductId, int Quantity);

// Abstracción chica a propósito (un solo método) para no inyectar IAmazonSQS
// directo en el endpoint: permite que los tests de integración reemplacen
// esto por un fake sin necesitar un mocking framework nuevo en el repo, y
// sin depender de credenciales/red real de AWS para correr "dotnet test".
public interface IPurchaseEventPublisher { Task PublishAsync(PurchaseCreatedEvent @event, CancellationToken cancellationToken); }

public sealed class SqsPurchaseEventPublisher(IAmazonSQS sqs, IConfiguration config) : IPurchaseEventPublisher
{
    public Task PublishAsync(PurchaseCreatedEvent @event, CancellationToken cancellationToken)
    {
        var queueUrl = config["SQS_QUEUE_URL"] ?? throw new InvalidOperationException("SQS_QUEUE_URL no está configurada.");
        return sqs.SendMessageAsync(new SendMessageRequest { QueueUrl = queueUrl, MessageBody = JsonSerializer.Serialize(@event) }, cancellationToken);
    }
}

public partial class Program;
