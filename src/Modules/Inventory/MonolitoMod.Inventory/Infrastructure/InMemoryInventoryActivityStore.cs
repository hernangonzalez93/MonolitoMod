using System.Collections.Concurrent;
using MonolitoMod.Inventory.Application;
using MonolitoMod.Inventory.Domain;
namespace MonolitoMod.Inventory.Infrastructure;
public sealed class InMemoryInventoryActivityStore : IInventoryActivityStore
{ private readonly ConcurrentQueue<InventoryAdjustment> adjustments = new(); public void Record(InventoryAdjustment adjustment) => adjustments.Enqueue(adjustment); public IReadOnlyCollection<InventoryAdjustment> GetAll() => adjustments.ToArray(); }
