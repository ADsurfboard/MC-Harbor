using System.Text.Json;
using MCHarbor.Windows.Models;

namespace MCHarbor.Windows.Services;

internal static class InstanceScanner
{
    public static IReadOnlyList<GameInstance> Scan(string gameRoot)
    {
        var versions = Path.Combine(gameRoot, "versions");
        if (!Directory.Exists(versions)) return [];

        var stores = PresetFiles(gameRoot).Select(ReadConfig).Where(store => store.HasValue)
            .Select(store => store!.Value).ToArray();
        var found = new List<GameInstance>();
        foreach (var directory in Directory.EnumerateDirectories(versions))
        {
            var id = Path.GetFileName(directory);
            if (string.IsNullOrWhiteSpace(id) || id.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) continue;
            var descriptor = Path.Combine(directory, id + ".json");
            if (!File.Exists(descriptor)) continue;
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllBytes(descriptor));
                var json = document.RootElement;
                if (json.ValueKind != JsonValueKind.Object) continue;
                var loader = DetectLoader(json);
                var version = ReadString(json, "gameVersion")
                    ?? ReadGamePatchVersion(json)
                    ?? ReadString(json, "inheritsFrom")
                    ?? id;
                var runDirectory = ResolveRunDirectory(gameRoot, directory, stores);
                found.Add(new GameInstance(
                    id,
                    version,
                    loader,
                    directory,
                    runDirectory,
                    FindIcon(directory),
                    Directory.GetLastWriteTimeUtc(directory)));
            }
            catch (JsonException)
            {
                // A damaged version descriptor should not hide other installed versions.
            }
            catch (IOException)
            {
                // A temporarily locked descriptor is retried on the next scan.
            }
            catch (InvalidOperationException)
            {
                // A descriptor with an unexpected JSON shape is ignored until repaired.
            }
        }

        return found.OrderByDescending(item => item.Modified).ToArray();
    }

    private static string DetectLoader(JsonElement json)
    {
        var coordinates = EnumerateArray(json, "libraries").Select(library => ReadString(library, "name"))
            .Concat(EnumerateArray(json, "patches").Select(patch => ReadString(patch, "id")));
        var value = string.Join(' ', coordinates).ToLowerInvariant();
        if (value.Contains("cleanroom")) return "cleanroom";
        if (value.Contains("neoforge")) return "neoforge";
        if (value.Contains("quilt")) return "quilt";
        if (value.Contains("legacyfabric")) return "legacyfabric";
        if (value.Contains("forge")) return "forge";
        if (value.Contains("fabric")) return "fabric";
        return "vanilla";
    }

    private static string? ReadString(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object
        && value.TryGetProperty(property, out var result)
        && result.ValueKind == JsonValueKind.String
            ? result.GetString()
            : null;

    private static string? ReadGamePatchVersion(JsonElement root)
    {
        if (!root.TryGetProperty("patches", out var patches) || patches.ValueKind != JsonValueKind.Array) return null;
        foreach (var patch in patches.EnumerateArray())
            if (ReadString(patch, "id") == "game") return ReadString(patch, "version");
        return null;
    }

    private static string ResolveRunDirectory(string gameRoot, string instanceDirectory, JsonElement[] stores)
    {
        if (File.Exists(Path.Combine(instanceDirectory, "modpack.json"))) return instanceDirectory;
        var settings = ReadConfig(Path.Combine(instanceDirectory, ".hmcl", "config", "instance-game-settings.json"));
        if (settings is { } current)
        {
            var overrides = EnumerateArray(current, "overrideProperties");
            if (overrides.Any(item => item.ValueKind == JsonValueKind.String && item.GetString() == "runningDirectory"))
                return ResolvePath(ReadString(current, "runningDirectory"), instanceDirectory);
        }
        else if (ReadConfig(Path.Combine(instanceDirectory, "hmclversion.cfg")) is { } legacy
            && legacy.TryGetProperty("gameDirType", out var kind))
        {
            if (kind.ToString() is "1" or "VERSION_FOLDER") return instanceDirectory;
            if (kind.ToString() is "2" or "CUSTOM") return ResolvePath(ReadString(legacy, "gameDir"), instanceDirectory);
            if (kind.ToString() is "0" or "ROOT_FOLDER") return gameRoot;
        }

        var requested = settings is { } local ? ReadString(local, "parent") : null;
        var presets = stores.SelectMany(store => EnumerateArray(store, "presets")).ToArray();
        var selected = requested is null ? default : presets.FirstOrDefault(row => ReadString(row, "id") == requested);
        if (selected.ValueKind == JsonValueKind.Undefined) selected = presets.FirstOrDefault();
        return ResolvePath(ReadString(selected, "runningDirectory"), gameRoot);
    }

    private static IEnumerable<string> PresetFiles(string root)
    {
        var workspace = Environment.GetEnvironmentVariable("HMCL_LOCAL_HOME");
        if (!string.IsNullOrWhiteSpace(workspace)) yield return Path.Combine(workspace, "config", "game-settings.json");
        yield return Path.Combine(root, ".hmcl", "config", "game-settings.json");
        if (Path.GetDirectoryName(root) is { } parent)
            yield return Path.Combine(parent, ".hmcl", "config", "game-settings.json");
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        yield return Path.Combine(roaming, ".hmcl", "config", "game-settings.json");
    }

    private static string ResolvePath(string? path, string fallback)
    {
        if (string.IsNullOrWhiteSpace(path)) return fallback;
        try { return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path), fallback); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException) { return fallback; }
    }

    private static JsonElement? ReadConfig(string file)
    {
        if (!File.Exists(file)) return null;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(file));
            return document.RootElement.ValueKind == JsonValueKind.Object ? document.RootElement.Clone() : null;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    private static IEnumerable<JsonElement> EnumerateArray(JsonElement node, string name) =>
        node.ValueKind == JsonValueKind.Object && node.TryGetProperty(name, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray() : [];

    private static string? FindIcon(string directory)
    {
        foreach (var name in new[] { "icon.png", "icon.jpg", Path.Combine(".hmcl", "icon.png") })
        {
            var path = Path.Combine(directory, name);
            if (File.Exists(path)) return path;
        }
        return null;
    }
}
