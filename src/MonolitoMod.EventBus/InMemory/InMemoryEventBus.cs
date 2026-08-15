using Microsoft.Extensions.DependencyInjection;
using MonolitoMod.EventBus.Abstractions;

namespace MonolitoMod.EventBus.InMemory;

public sealed class InMemoryEventBus(IServiceScopeFactory scopeFactory) : IEventBus
{
    public async Task PublishAsync<TEvent>(TEvent @event, CancellationToken cancellationToken = default) where TEvent : IIntegrationEvent
    {
        using var scope = scopeFactory.CreateScope();
        foreach (var handler in scope.ServiceProvider.GetServices<IIntegrationEventHandler<TEvent>>()) await handler.HandleAsync(@event, cancellationToken);
    }
}
