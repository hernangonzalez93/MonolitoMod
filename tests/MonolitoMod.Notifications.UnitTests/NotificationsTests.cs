using MonolitoMod.Contracts.Purchases;
using MonolitoMod.Notifications.Application.PurchaseCreated;
using MonolitoMod.Notifications.Infrastructure;
using Xunit;
namespace MonolitoMod.Notifications.UnitTests;
public sealed class NotificationsTests { [Fact] public async Task Records_confirmation() { var store = new InMemoryNotificationStore(); await new SendPurchaseConfirmationHandler(store).HandleAsync(new PurchaseCreatedEvent(Guid.NewGuid(), "buyer@example.com", [new("book", 1)], DateTimeOffset.UtcNow), CancellationToken.None); Assert.Equal("buyer@example.com", Assert.Single(store.GetAll()).RecipientEmail); } }
