using MonolitoMod.Inventory.Domain;
namespace MonolitoMod.Inventory.Application;
public interface IInventoryActivityStore { void Record(InventoryAdjustment adjustment); IReadOnlyCollection<InventoryAdjustment> GetAll(); }
