using Microsoft.Extensions.DependencyInjection;
using MonolitoMod.EventBus.Abstractions;
using MonolitoMod.EventBus.InMemory;

namespace MonolitoMod.EventBus.DependencyInjection;

public static class EventBusServiceCollectionExtensions
{
    public static IServiceCollection AddInMemoryEventBus(this IServiceCollection services)
    { services.AddSingleton<IEventBus, InMemoryEventBus>(); return services; }
}
