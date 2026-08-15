using MonolitoMod.Contracts.Purchases;
using MonolitoMod.Inventory.Application.PurchaseCreated;
using MonolitoMod.Inventory.Infrastructure;
using Xunit;
namespace MonolitoMod.Inventory.UnitTests;
public sealed class InventoryTests { [Fact] public async Task Records_each_item() { var store = new InMemoryInventoryActivityStore(); await new AdjustInventoryOnPurchaseCreatedHandler(store).HandleAsync(new PurchaseCreatedEvent(Guid.NewGuid(), "buyer@example.com", [new("book", 2), new("pen", 1)], DateTimeOffset.UtcNow), CancellationToken.None); Assert.Equal(2, store.GetAll().Count); } }
