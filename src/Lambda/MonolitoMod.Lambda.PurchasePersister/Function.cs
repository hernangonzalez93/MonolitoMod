using System.Text.Json;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using MonolitoMod.Contracts.Purchases;
using Npgsql;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace MonolitoMod.Lambda.PurchasePersister;

// Sin EF Core a propósito: para una función tan chica (deserializar +
// insertar), el costo de arranque en frío que agrega un ORM completo no se
// justifica en Lambda. Npgsql directo (ADO.NET) alcanza y arranca más rápido.
public sealed class Function
{
    // Cacheados a nivel de clase (no de método): el entorno de ejecución de
    // Lambda se reutiliza entre invocaciones mientras esté "caliente" — esto
    // evita volver a pedirle el secreto a Secrets Manager o re-crear el
    // esquema en cada mensaje, solo en el primer arranque en frío.
    private static string? connectionString;
    private static bool schemaEnsured;

    public async Task FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
    {
        await using var connection = new NpgsqlConnection(await GetConnectionStringAsync());
        await connection.OpenAsync();
        await EnsureSchemaAsync(connection);

        foreach (var record in sqsEvent.Records)
        {
            var purchase = JsonSerializer.Deserialize<PurchaseCreatedEvent>(record.Body)
                ?? throw new InvalidOperationException($"No se pudo deserializar el mensaje {record.MessageId}.");
            await PersistAsync(connection, purchase);
            context.Logger.LogInformation($"Persistida la compra {purchase.PurchaseId} ({purchase.Items.Count} items).");
        }
    }

    private static async Task PersistAsync(NpgsqlConnection connection, PurchaseCreatedEvent purchase)
    {
        await using var transaction = await connection.BeginTransactionAsync();

        await using (var cmd = new NpgsqlCommand(
            "INSERT INTO purchases (id, customer_email, occurred_on_utc) VALUES (@id, @email, @occurred) ON CONFLICT (id) DO NOTHING",
            connection, transaction))
        {
            cmd.Parameters.AddWithValue("id", purchase.PurchaseId);
            cmd.Parameters.AddWithValue("email", purchase.CustomerEmail);
            cmd.Parameters.AddWithValue("occurred", purchase.OccurredOnUtc);
            await cmd.ExecuteNonQueryAsync();
        }

        foreach (var item in purchase.Items)
        {
            await using var cmd = new NpgsqlCommand(
                "INSERT INTO purchase_items (purchase_id, product_id, quantity) VALUES (@purchaseId, @productId, @quantity)",
                connection, transaction);
            cmd.Parameters.AddWithValue("purchaseId", purchase.PurchaseId);
            cmd.Parameters.AddWithValue("productId", item.ProductId);
            cmd.Parameters.AddWithValue("quantity", item.Quantity);
            await cmd.ExecuteNonQueryAsync();
        }

        await transaction.CommitAsync();
    }

    // "CREATE TABLE IF NOT EXISTS" en vez de un mecanismo de migraciones
    // formal: alcanza para el esquema de esta fase (2 tablas, sin cambios
    // posteriores previstos) y no depende de tener acceso externo a la base
    // para aplicar una migración — la Fase 13 todavía no resolvió cómo
    // conectarse desde afuera.
    private static async Task EnsureSchemaAsync(NpgsqlConnection connection)
    {
        if (schemaEnsured) return;
        await using var cmd = new NpgsqlCommand(
            """
            CREATE TABLE IF NOT EXISTS purchases (
                id UUID PRIMARY KEY,
                customer_email TEXT NOT NULL,
                occurred_on_utc TIMESTAMPTZ NOT NULL
            );
            CREATE TABLE IF NOT EXISTS purchase_items (
                purchase_id UUID NOT NULL REFERENCES purchases(id),
                product_id TEXT NOT NULL,
                quantity INT NOT NULL
            );
            """, connection);
        await cmd.ExecuteNonQueryAsync();
        schemaEnsured = true;
    }

    private static async Task<string> GetConnectionStringAsync()
    {
        if (connectionString is not null) return connectionString;

        var secretArn = Environment.GetEnvironmentVariable("DB_SECRET_ARN") ?? throw new InvalidOperationException("DB_SECRET_ARN no configurada.");
        using var secretsClient = new AmazonSecretsManagerClient();
        var secretValue = await secretsClient.GetSecretValueAsync(new GetSecretValueRequest { SecretId = secretArn });
        var credentials = JsonSerializer.Deserialize<DbCredentials>(secretValue.SecretString, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("No se pudo leer el secreto de RDS.");

        var host = Environment.GetEnvironmentVariable("DB_HOST") ?? throw new InvalidOperationException("DB_HOST no configurada.");
        var port = Environment.GetEnvironmentVariable("DB_PORT") ?? "5432";
        var dbName = Environment.GetEnvironmentVariable("DB_NAME") ?? throw new InvalidOperationException("DB_NAME no configurada.");

        // SSL Mode=Require sin validar el certificado contra la CA de RDS
        // (Trust Server Certificate=true): cifra la conexión en tránsito,
        // pero no confirma la identidad del servidor. Suficiente para esta
        // fase (la conexión ya está confinada a una VPC privada sin salida
        // a internet — Fase 9); una versión más estricta usaría el
        // certificado raíz de RDS con SSL Mode=VerifyFull.
        connectionString = $"Host={host};Port={port};Database={dbName};Username={credentials.Username};Password={credentials.Password};SSL Mode=Require;Trust Server Certificate=true";
        return connectionString;
    }

    private sealed record DbCredentials(string Username, string Password);
}
