using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal static class LittleSkinClient
{
    private static readonly Uri Origin = new("https://littleskin.cn/");
    private static string FavoritesFile => Path.Combine(AppPaths.DataDirectory, "skins", "littleskin-favorites.json");

    public static async Task<(LittleSkinEntry[] Rows, int LastPage)> SearchAsync(string query, int page, bool popular)
    {
        var request = $"skinlib/list?filter=skin&keyword={Uri.EscapeDataString(query)}&page={page}&sort={(popular ? "likes" : "time")}";
        var root = await HarborHttp.JsonAsync(HarborHttp.Service, new Uri(Origin, request)) as JsonObject
            ?? throw new IOException("LittleSkin 皮肤列表无法读取。");
        var entries = (root["data"] as JsonArray ?? []).OfType<JsonObject>().Where(item =>
            item["type"]?.GetValue<string>() is "steve" or "alex" && item["tid"]?.GetValue<int>() > 0)
            .Select(item => new LittleSkinEntry(item["tid"]!.GetValue<int>(), item["name"]?.GetValue<string>() ?? "",
                item["nickname"]?.GetValue<string>() ?? "", item["type"]!.GetValue<string>(),
                item["hd"]?.GetValue<bool>() ?? false)).Take(100).ToArray();
        return (entries, Math.Max(1, root["last_page"]?.GetValue<int>() ?? page));
    }

    public static async Task<string> GetSkinAsync(LittleSkinEntry entry)
    {
        if (entry.Hd) throw new IOException("请选择 64×64 或 64×32 的标准皮肤。");
        var info = await HarborHttp.JsonAsync(HarborHttp.Service, new Uri(Origin, $"texture/{entry.Id}"));
        var digest = info?["hash"]?.GetValue<string>() ?? "";
        if (info?["type"]?.GetValue<string>() != entry.Type || digest.Length != 64 || !digest.All(Uri.IsHexDigit))
            throw new IOException("LittleSkin 返回的皮肤信息无效。");
        digest = digest.ToLowerInvariant();
        var file = Path.Combine(AppPaths.DataDirectory, "skins", "littleskin", digest + ".png");
        if (File.Exists(file) && new FileInfo(file).Length <= 4_000_000
            && Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(file))).Equals(digest, StringComparison.OrdinalIgnoreCase))
            return file;
        var bytes = await HarborHttp.RequestAsync(HarborHttp.Downloads, new Uri(Origin, $"textures/{digest}"), 4_000_000);
        ValidateSkin(bytes);
        if (!Convert.ToHexString(SHA256.HashData(bytes)).Equals(digest, StringComparison.OrdinalIgnoreCase))
            throw new IOException("皮肤文件的 SHA-256 校验失败。");
        AccountStore.WriteAtomically(file, bytes);
        return file;
    }

    public static LittleSkinEntry[] ReadFavorites()
    {
        if (!File.Exists(FavoritesFile)) return [];
        return JsonSerializer.Deserialize<LittleSkinEntry[]>(File.ReadAllBytes(FavoritesFile)) ?? [];
    }

    public static bool ToggleFavorite(LittleSkinEntry entry)
    {
        var rows = ReadFavorites();
        var present = rows.Any(item => item.Id == entry.Id);
        var updated = present ? rows.Where(item => item.Id != entry.Id) : rows.Prepend(entry);
        AccountStore.WriteAtomically(FavoritesFile, JsonSerializer.SerializeToUtf8Bytes(updated.ToArray()));
        return !present;
    }

    public static void ValidateSkin(byte[] bytes)
    {
        if (bytes.Length < 24 || bytes.Length > 4_000_000
            || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })
            || BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4)) != 64
            || BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4)) is not (32 or 64))
            throw new IOException("请选择 64×64 或 64×32 Minecraft PNG 皮肤。");
    }
}

public sealed record LittleSkinEntry(int Id, string Name, string Author, string Type, bool Hd)
{
    public string Label => $"{Name} · {Author}" + (Hd ? " · 高清" : "");
    public bool Slim => Type == "alex";
}
