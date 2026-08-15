namespace MonolitoMod.Inventory.Domain;
public sealed record InventoryAdjustment(Guid PurchaseId, string ProductId, int Quantity);
