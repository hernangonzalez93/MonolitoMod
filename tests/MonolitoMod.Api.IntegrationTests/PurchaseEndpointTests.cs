using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using MonolitoMod.Contracts.Purchases;
using MonolitoMod.Inventory.Application;
using MonolitoMod.Notifications.Application;
using Xunit;
namespace MonolitoMod.Api.IntegrationTests;

public sealed class FakePurchaseEventPublisher : IPurchaseEventPublisher
{
    public List<PurchaseCreatedEvent> Published { get; } = [];
    public Task PublishAsync(PurchaseCreatedEvent @event, CancellationToken cancellationToken) { Published.Add(@event); return Task.CompletedTask; }
}

public sealed class PurchaseEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> factory;
    private readonly FakePurchaseEventPublisher publisher = new();

    // Reemplaza el publisher real (que llamaría a SQS de verdad) por el fake:
    // "dotnet test" no depende de credenciales ni de red hacia AWS.
    public PurchaseEndpointTests(WebApplicationFactory<Program> factory) => this.factory = factory.WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton<IPurchaseEventPublisher>(publisher)));

    [Fact]
    public async Task Purchase_reaches_both_modules_and_publishes_to_sqs()
    {
        var result = await factory.CreateClient().PostAsJsonAsync("/api/purchases", new { customerEmail = "buyer@example.com", items = new[] { new { productId = "book", quantity = 2 } } }, CancellationToken.None);
        Assert.Equal(HttpStatusCode.Accepted, result.StatusCode);
        using var scope = factory.Services.CreateScope();
        Assert.Single(scope.ServiceProvider.GetRequiredService<IInventoryActivityStore>().GetAll());
        Assert.Single(scope.ServiceProvider.GetRequiredService<INotificationStore>().GetAll());
        Assert.Single(publisher.Published);
    }
}
