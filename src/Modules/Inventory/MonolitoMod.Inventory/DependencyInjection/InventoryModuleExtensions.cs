using Microsoft.Extensions.DependencyInjection;
using MonolitoMod.Contracts.Purchases;
using MonolitoMod.EventBus.Abstractions;
using MonolitoMod.Inventory.Application;
using MonolitoMod.Inventory.Application.PurchaseCreated;
using MonolitoMod.Inventory.Infrastructure;
namespace MonolitoMod.Inventory.DependencyInjection;
public static class InventoryModuleExtensions { public static IServiceCollection AddInventoryModule(this IServiceCollection services) { services.AddSingleton<IInventoryActivityStore, InMemoryInventoryActivityStore>(); services.AddTransient<IIntegrationEventHandler<PurchaseCreatedEvent>, AdjustInventoryOnPurchaseCreatedHandler>(); return services; } }
