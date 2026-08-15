using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using MonolitoMod.Inventory.Application;
using MonolitoMod.Notifications.Application;
using Xunit;
namespace MonolitoMod.Api.IntegrationTests;
public sealed class PurchaseEndpointTests(WebApplicationFactory<Program> factory) : IClassFixture<WebApplicationFactory<Program>> { [Fact] public async Task Purchase_reaches_both_modules() { var result = await factory.CreateClient().PostAsJsonAsync("/api/purchases", new { customerEmail = "buyer@example.com", items = new[] { new { productId = "book", quantity = 2 } } }, CancellationToken.None); Assert.Equal(HttpStatusCode.Accepted, result.StatusCode); using var scope = factory.Services.CreateScope(); Assert.Single(scope.ServiceProvider.GetRequiredService<IInventoryActivityStore>().GetAll()); Assert.Single(scope.ServiceProvider.GetRequiredService<INotificationStore>().GetAll()); } }
