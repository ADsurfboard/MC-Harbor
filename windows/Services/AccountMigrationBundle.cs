using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal static class AccountMigrationBundle
{
    private const int Version = 1;
    private const int Iterations = 600_000;
    private const int MaximumBytes = 16_000_000;
    private static readonly byte[] AssociatedData = Encoding.UTF8.GetBytes("mc-harbor/account-migration/v1");

    public static JsonObject Decrypt(ReadOnlySpan<byte> input, string passphrase)
    {
        if (input.Length is 0 or > MaximumBytes) throw new IOException("迁移包大小超出限制。");
        if (passphrase.Length < 12) throw new IOException("迁移口令至少需要 12 个字符。");

        JsonObject envelope;
        try { envelope = JsonNode.Parse(input)?.AsObject() ?? throw new JsonException(); }
        catch (JsonException error) { throw new IOException("迁移文件不是有效的 JSON。", error); }

        if (ReadString(envelope, "schema") != "mc-harbor/account-migration"
            || ReadInt(envelope, "version") != Version
            || ReadString(envelope, "kdf") != "PBKDF2-HMAC-SHA256"
            || ReadInt(envelope, "iterations") != Iterations)
            throw new IOException("不支持此迁移包格式。");

        var salt = ReadBase64(envelope, "salt", 16);
        var nonce = ReadBase64(envelope, "nonce", 12);
        var ciphertext = ReadBase64(envelope, "ciphertext", maximum: MaximumBytes);
        var tag = ReadBase64(envelope, "tag", 16);
        if (ciphertext.Length is 0 or > MaximumBytes) throw new IOException("迁移包内容超出限制。");

        byte[]? key = null;
        var plaintext = new byte[ciphertext.Length];
        try
        {
            key = Rfc2898DeriveBytes.Pbkdf2(passphrase.Normalize(NormalizationForm.FormC), salt,
                Iterations, HashAlgorithmName.SHA256, 32);
            using var cipher = new AesGcm(key, tag.Length);
            cipher.Decrypt(nonce, ciphertext, tag, plaintext, AssociatedData);
            return ValidatePayload(JsonNode.Parse(plaintext)?.AsObject()
                ?? throw new IOException("解密内容不是有效的账号迁移数据。"));
        }
        catch (CryptographicException error)
        {
            throw new IOException("口令错误或迁移包内容已损坏。", error);
        }
        catch (JsonException error)
        {
            throw new IOException("迁移包内容无法读取。", error);
        }
        finally
        {
            if (key is not null) CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(ciphertext);
            CryptographicOperations.ZeroMemory(salt);
            CryptographicOperations.ZeroMemory(nonce);
            CryptographicOperations.ZeroMemory(tag);
        }
    }

    private static JsonObject ValidatePayload(JsonObject payload)
    {
        if (ReadString(payload, "schema") != "mc-harbor/account-migration"
            || ReadInt(payload, "version") != Version || payload["accounts"] is not JsonArray accounts
            || accounts.Count is 0 or > 64)
            throw new IOException("迁移包账号清单无效。");

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in accounts)
        {
            if (value is not JsonObject account || account["metadata"] is not JsonObject metadata
                || account["hmclMetadata"] is not JsonObject hmclMetadata
                || account["privateData"] is not JsonObject privateData)
                throw new IOException("迁移包包含不完整的账号数据。");
            var id = ReadString(metadata, "id");
            var kind = ReadString(metadata, "kind");
            if (string.IsNullOrWhiteSpace(id) || id.Length > 256 || !ids.Add(id)
                || kind is not ("microsoft" or "authlibInjector"))
                throw new IOException("迁移包包含重复或不支持的账号。");
            if (hmclMetadata.Count == 0 || privateData.Count == 0)
                throw new IOException("迁移包缺少可用的登录凭据。");
        }
        return payload;
    }

    private static string ReadString(JsonObject row, string name)
    {
        try { return row[name]?.GetValue<string>() ?? ""; }
        catch (InvalidOperationException) { return ""; }
    }

    private static int ReadInt(JsonObject row, string name)
    {
        try { return row[name]?.GetValue<int>() ?? 0; }
        catch (InvalidOperationException) { return 0; }
        catch (FormatException) { return 0; }
    }

    private static byte[] ReadBase64(JsonObject row, string name, int exact = -1, int maximum = 1024)
    {
        var value = ReadString(row, name);
        if (value.Length == 0 || value.Length > maximum * 2 || value.Any(char.IsWhiteSpace))
            throw new IOException("迁移包加密字段无效。");
        byte[] decoded;
        try { decoded = Convert.FromBase64String(value); }
        catch (FormatException error) { throw new IOException("迁移包加密字段无效。", error); }
        if ((exact >= 0 && decoded.Length != exact) || decoded.Length > maximum)
        {
            CryptographicOperations.ZeroMemory(decoded);
            throw new IOException("迁移包加密字段大小无效。");
        }
        return decoded;
    }
}
