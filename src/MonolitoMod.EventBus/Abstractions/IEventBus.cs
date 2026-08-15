namespace MonolitoMod.EventBus.Abstractions;

public interface IEventBus { Task PublishAsync<TEvent>(TEvent @event, CancellationToken cancellationToken = default) where TEvent : IIntegrationEvent; }
