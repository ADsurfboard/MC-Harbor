using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;

namespace MCHarbor.Windows.Services;

internal sealed class ResourceCatalog(BridgeClient bridge)
{
    private static readonly Lazy<Task<(string Chinese, string English)[]>> LocalNames = new(
        () => Task.Run(ReadLocalNames));

    public async Task<(CatalogProject[] Rows, int Total)> SearchAsync(string source, string kind, string query,
        GameInstance? instance, int page, bool updated, CancellationToken cancellation)
    {
        var names = query.Any(ch => ch >= '\u3400' && ch <= '\u9fff') ? await LocalNames.Value : [];
        var english = names.FirstOrDefault(item => item.Chinese.Split('/').Contains(query, StringComparer.OrdinalIgnoreCase)).English
            ?? names.FirstOrDefault(item => item.Chinese.Contains(query, StringComparison.OrdinalIgnoreCase)).English;
        if (!string.IsNullOrWhiteSpace(english)) query = english;
        if (source == "curseforge")
        {
            var args = Arguments(kind, instance);
            args["query"] = query;
            args["page"] = page;
            args["updated"] = updated;
            var result = await bridge.InvokeAsync("cfSearch", args, cancellationToken: cancellation);
            var rows = (result["hits"] as JsonArray ?? []).OfType<JsonObject>().Select(row => new CatalogProject(
                S(row, "projectId"), source, kind, S(row, "title"), S(row, "description"), S(row, "author"), S(row, "pageUrl"))).ToArray();
            return (rows, result["totalHits"]?.GetValue<int>() ?? rows.Length);
        }

        var facets = new List<string[]> { new[] { $"project_type:{kind}" } };
        if (instance is not null && instance.Version.Length > 0) facets.Add([$"versions:{instance.Version}"]);
        if (kind == "mod" && Loader(instance) is { Length: > 0 } loader) facets.Add([$"categories:{loader}"]);
        var path = $"/search?query={Uri.EscapeDataString(query)}&limit=30&offset={page * 30}"
            + $"&index={(updated ? "updated" : query.Length == 0 ? "downloads" : "relevance")}"
            + "&facets=" + Uri.EscapeDataString(JsonSerializer.Serialize(facets));
        var response = await ModrinthAsync(path, cancellation);
        var hits = (response?["hits"] as JsonArray ?? []).OfType<JsonObject>().Select(row => new CatalogProject(
            S(row, "project_id"), "modrinth", kind, S(row, "title"), S(row, "description"), S(row, "author"),
            $"https://modrinth.com/{kind}/{Uri.EscapeDataString(S(row, "slug"))}")).ToArray();
        return (hits, response?["total_hits"]?.GetValue<int>() ?? hits.Length);
    }

    public async Task<CatalogVersion[]> VersionsAsync(CatalogProject project, GameInstance? instance, CancellationToken cancellation)
    {
        if (!IsId(project.Id)) throw new IOException("资源编号无效。");
        var args = Arguments(project.Kind, instance);
        if (project.Source == "curseforge")
        {
            args["project"] = project.Id;
            var result = await bridge.InvokeAsync("cfVersions", args, cancellationToken: cancellation);
            return ReadVersions(result["versions"], modrinth: false).Take(50).ToArray();
        }
        var filters = VersionFilters(project.Kind, instance);
        return ReadVersions(await ModrinthAsync($"/project/{project.Id}/version?{filters}", cancellation), modrinth: true).Take(50).ToArray();
    }

    public async Task<CatalogFile[]> PlanAsync(CatalogProject project, CatalogVersion version, GameInstance? instance,
        CancellationToken cancellation)
    {
        if (!IsId(project.Id) || !IsId(version.Id)) throw new IOException("资源或文件编号无效。");
        var args = Arguments(project.Kind, instance);
        if (project.Source == "curseforge")
        {
            args["project"] = project.Id;
            args["file"] = version.Id;
            var result = await bridge.InvokeAsync("cfPlan", args, cancellationToken: cancellation);
            return ReadVersions(result["versions"], modrinth: false).Select(SelectFile).ToArray();
        }
        var selected = new Dictionary<string, CatalogVersion>(StringComparer.Ordinal);
        var files = new List<CatalogFile>();
        await VisitAsync(version);
        return files.ToArray();

        async Task VisitAsync(CatalogVersion item)
        {
            if (!IsId(item.Project) || !IsId(item.Id)) throw new IOException("依赖编号无效。");
            if (selected.TryGetValue(item.Project, out var previous))
            {
                if (previous.Id != item.Id) throw new IOException("必需依赖要求不同版本。");
                return;
            }
            if (selected.Count >= 40) throw new IOException("安装依赖数量超过上限。");
            if (instance is not null && !item.GameVersions.Contains(instance.Version, StringComparer.OrdinalIgnoreCase))
                throw new IOException($"资源 {item.Name} 没有适用于 {instance.Version} 的版本。");
            if (project.Kind == "mod" && Loader(instance) is { Length: > 0 } loader
                && !item.Loaders.Contains(loader, StringComparer.OrdinalIgnoreCase))
                throw new IOException($"资源 {item.Name} 与实例加载器不兼容。");
            selected.Add(item.Project, item);
            if (project.Kind == "mod")
            {
                foreach (var dependency in item.Required)
                {
                    CatalogVersion? child;
                    if (IsId(dependency.Version))
                    {
                        var node = await ModrinthAsync($"/version/{dependency.Version}", cancellation);
                        child = node is JsonObject value ? ReadVersion(value, modrinth: true) : null;
                    }
                    else if (IsId(dependency.Project))
                    {
                        if (selected.ContainsKey(dependency.Project)) continue;
                        child = (await VersionsAsync(project with { Id = dependency.Project }, instance, cancellation)).FirstOrDefault();
                    }
                    else child = null;
                    if (child is null) throw new IOException("必需依赖没有可安装的兼容文件。");
                    await VisitAsync(child);
                }
            }
            files.Add(SelectFile(item));
        }
    }

    public async Task DownloadAsync(CatalogFile file, string destination, CancellationToken cancellation)
    {
        if (!Uri.TryCreate(file.Url, UriKind.Absolute, out var original) || original.Scheme != "https" || original.UserInfo.Length != 0)
            throw new IOException("资源下载地址无效。");
        if (file.Size is < 0 or > 2_000_000_000) throw new IOException("资源文件过大。");
        var entry = file.Hashes.FirstOrDefault(hash => hash.Key == "sha512");
        if (entry.Value is null) entry = file.Hashes.FirstOrDefault(hash => hash.Key == "sha1");
        if (entry.Value is null) entry = file.Hashes.FirstOrDefault(hash => hash.Key == "md5");
        if (entry.Value is null) throw new IOException("平台未提供可校验的文件摘要。");
        var order = AppPaths.GetPreference("downloadSource", "auto");
        var candidates = new List<Uri> { original };
        if (original.Host is "cdn.modrinth.com" or "edge.forgecdn.net")
            candidates.Insert(order == "official" ? candidates.Count : 0, new UriBuilder(original) { Host = "mod.mcimirror.top" }.Uri);
        foreach (var uri in candidates)
        {
            try
            {
                await DownloadFileAsync(uri, destination, file.Size, entry.Key, entry.Value, cancellation);
                return;
            }
            catch (Exception error) when (!cancellation.IsCancellationRequested
                && error is IOException or HttpRequestException or OperationCanceledException)
            {
                if (File.Exists(destination)) File.Delete(destination);
                if (uri == candidates[^1]) throw new IOException($"无法下载或校验 {file.Name}。{error.Message}", error);
            }
        }
    }

    private static async Task DownloadFileAsync(Uri uri, string destination, long size, string hash, string expected,
        CancellationToken cancellation)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        limit.CancelAfter(TimeSpan.FromMinutes(25));
        using var response = await HarborHttp.Downloads.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, limit.Token);
        response.EnsureSuccessStatusCode();
        if (response.RequestMessage?.RequestUri?.Scheme != "https") throw new IOException("下载连接未保持 HTTPS。");
        using var hasher = System.Security.Cryptography.IncrementalHash.CreateHash(new System.Security.Cryptography.HashAlgorithmName(hash.ToUpperInvariant()));
        using var input = await response.Content.ReadAsStreamAsync(limit.Token);
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true);
        var buffer = new byte[128 * 1024];
        long bytes = 0;
        int received;
        while ((received = await input.ReadAsync(buffer, limit.Token)) > 0)
        {
            bytes += received;
            if (bytes > 2_000_000_000 || (size > 0 && bytes > size)) throw new IOException("实际下载大小超过声明大小。");
            hasher.AppendData(buffer, 0, received);
            await output.WriteAsync(buffer.AsMemory(0, received), limit.Token);
        }
        if (bytes == 0 || (size > 0 && bytes != size)
            || !Convert.ToHexString(hasher.GetHashAndReset()).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new IOException("下载文件完整性校验失败。");
    }

    public static string? Loader(GameInstance? instance) => instance?.Loader switch
    {
        null or "" or "vanilla" => null,
        "legacyfabric" => "fabric",
        "cleanroom" => "forge",
        var value => value
    };

    private static Dictionary<string, object?> Arguments(string kind, GameInstance? instance) => new()
    {
        ["kind"] = kind, ["version"] = instance?.Version ?? "", ["loader"] = Loader(instance) ?? ""
    };

    private static string VersionFilters(string kind, GameInstance? instance)
    {
        var filters = new List<string>();
        if (instance is not null) filters.Add("game_versions=" + Uri.EscapeDataString(JsonSerializer.Serialize(new[] { instance.Version })));
        if (kind == "mod" && Loader(instance) is { } loader)
            filters.Add("loaders=" + Uri.EscapeDataString(JsonSerializer.Serialize(new[] { loader })));
        return string.Join("&", filters);
    }

    private static async Task<JsonNode?> ModrinthAsync(string path, CancellationToken cancellation)
    {
        var official = "https://api.modrinth.com/v2";
        var mirror = "https://mod.mcimirror.top/modrinth/v2";
        var endpoints = AppPaths.GetPreference("downloadSource") == "official" ? new[] { official, mirror } : [mirror, official];
        for (var index = 0; index < endpoints.Length; index++)
        {
            try
            {
                return await HarborHttp.JsonAsync(HarborHttp.Service, new Uri(endpoints[index] + path), cancellation: cancellation);
            }
            catch (Exception error) when (index == 0 && !cancellation.IsCancellationRequested
                && error is HttpRequestException or IOException or OperationCanceledException or JsonException) { }
        }
        throw new IOException("Modrinth 暂不可用。");
    }

    private static IEnumerable<CatalogVersion> ReadVersions(JsonNode? node, bool modrinth) =>
        (node as JsonArray ?? []).OfType<JsonObject>().Select(row => ReadVersion(row, modrinth));

    private static CatalogVersion ReadVersion(JsonObject row, bool modrinth)
    {
        var files = (row["files"] as JsonArray ?? []).OfType<JsonObject>().Select(file => new CatalogFile(
            S(file, "filename"), S(file, "url"), file["size"]?.GetValue<long>() ?? 0,
            file["primary"]?.GetValue<bool>() ?? false, file["hashes"]?.Deserialize<Dictionary<string, string>>() ?? [])).ToArray();
        var required = (row["dependencies"] as JsonArray ?? []).OfType<JsonObject>().Where(item => S(item, "dependency_type") == "required")
            .Select(item => new CatalogDependency(S(item, "project_id"), S(item, "version_id"))).ToArray();
        return new CatalogVersion(S(row, "id"), S(row, modrinth ? "project_id" : "projectId"), S(row, "name"),
            Strings(row[modrinth ? "game_versions" : "gameVersions"]), Strings(row["loaders"]), files, required);
    }

    private static CatalogFile SelectFile(CatalogVersion value)
    {
        var file = value.Files.FirstOrDefault(candidate => candidate.Primary) ?? value.Files.FirstOrDefault()
            ?? throw new IOException($"平台未提供 {value.Name} 的直接下载。");
        return file with { Project = value.Project, Version = value.Id };
    }

    private static string S(JsonNode? item, string field) => item?[field]?.GetValue<string>() ?? "";
    private static string[] Strings(JsonNode? value) => (value as JsonArray ?? []).Select(row => row?.GetValue<string>() ?? "").ToArray();
    private static bool IsId(string value) => value.Length is > 0 and <= 60 && value.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_');

    private static (string Chinese, string English)[] ReadLocalNames()
    {
        using var jar = ZipFile.OpenRead(AppPaths.HmclJar);
        var data = jar.GetEntry("assets/mod_data.txt");
        if (data is null) return [];
        using var reader = new StreamReader(data.Open());
        var rows = new List<(string, string)>();
        while (reader.ReadLine() is { } line)
        {
            if (line.StartsWith('#')) continue;
            var fields = line.Split(';');
            if (fields.Length >= 5 && fields[3].Any(ch => ch is >= '\u3400' and <= '\u9fff'))
                rows.Add((fields[3], string.IsNullOrWhiteSpace(fields[4]) ? fields[0] : fields[4]));
        }
        return rows.OrderBy(row => row.Item1.Length).ToArray();
    }
}

public sealed record CatalogProject(string Id, string Source, string Kind, string Name, string Description, string Author, string PageUrl)
{
    public string Label => $"{Name} · {Author}";
}

public sealed record CatalogVersion(string Id, string Project, string Name, string[] GameVersions, string[] Loaders,
    CatalogFile[] Files, CatalogDependency[] Required);
public sealed record CatalogFile(string Name, string Url, long Size, bool Primary, Dictionary<string, string> Hashes)
{
    public string Project { get; init; } = "";
    public string Version { get; init; } = "";
}
public sealed record CatalogDependency(string Project, string Version);
