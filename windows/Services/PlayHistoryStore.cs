using System.Text.Json;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;

namespace MCHarbor.Windows.Services;

internal static class PlayHistoryStore
{
    private static string HistoryFile => Path.Combine(AppPaths.DataDirectory, "social", "windows-history.json");

    public static void Complete(GameInstance instance, Guid session, string[] peers)
    {
        var id = session.ToString().ToUpperInvariant();
        var path = Path.Combine(AppPaths.DataDirectory, "social", "receipts", id + ".json");
        if (!File.Exists(path)) return;
        var receipt = JsonNode.Parse(File.ReadAllBytes(path)) as JsonObject;
        if (receipt?["id"]?.GetValue<string>() != id || receipt["finished"]?.GetValue<bool>() != true) return;
        var start = receipt["started"]?.GetValue<double>() ?? 0;
        var seconds = receipt["seconds"]?.GetValue<double>() ?? 0;
        if (!double.IsFinite(start) || !double.IsFinite(seconds) || start <= 0 || seconds < 0) return;
        var records = Read().Where(item => item.Id != id).Prepend(new PlayRecord(id, instance.Id,
            instance.Version, instance.Loader, receipt["world"]?.GetValue<string>() ?? "", start, seconds, peers)).Take(1000).ToArray();
        AccountStore.WriteAtomically(HistoryFile, JsonSerializer.SerializeToUtf8Bytes(records, FriendsClient.JsonOptions));
        File.Delete(path);
    }

    public static PlayRecord[] Read()
    {
        if (!File.Exists(HistoryFile)) return [];
        return JsonSerializer.Deserialize<PlayRecord[]>(File.ReadAllBytes(HistoryFile), FriendsClient.JsonOptions) ?? [];
    }
}

internal sealed record PlayRecord(string Id, string Instance, string Version, string Loader, string World,
    double Started, double Seconds, string[] Friends);
