using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal sealed class TerracottaClient : IAsyncDisposable
{
    private const string Executable = "terracotta-0.4.2-windows-x86_64.exe";
    private const string Sha256 = "07ebe139e3ca5f74576e58b1a96efe59abdfbe148d3f1a49bfdca8b6f70745f0";
    private static readonly string ReleaseUrl =
        "https://github.com/burningtnt/Terracotta/releases/download/v0.4.2/terracotta-0.4.2-windows-x86_64-pkg.tar.gz";
    private static readonly Dictionary<string, string> FileHashes = new(StringComparer.OrdinalIgnoreCase)
    {
        [Executable] = "6e98d1f2380ed22fb5a2dd4aafce6c773e9cf69100c8bb8e49e7d6983756bdb9a31f80e06bcfbe5a2742144fe806d3d687dec54d8f09d87c659341f99dd9fd80",
        ["VCRUNTIME140.DLL"] = "3d4b24061f72c0e957c7b04a0c4098c94c8f1afb4a7e159850b9939c7210d73398be6f27b5ab85073b4e8c999816e7804fef0f6115c39cd061f4aaeb4dcda8cf"
    };

    private WindowsProcessJob? _job;
    private string? _session;
    private int _port;
    private bool _roomOwned;

    public async Task OpenRoomAsync(string? code, string player, CancellationToken cancellation)
    {
        if (_job is not null || _port != 0) throw new InvalidOperationException("请先退出当前陶瓦房间。");
        if (code is not null && !IsRoomCode(code)) throw new FormatException("请输入完整的陶瓦房间码。");
        var binary = await PrepareBinaryAsync(cancellation);
        var root = Path.Combine(AppPaths.DataDirectory, "network", "terracotta", "sessions");
        _session = Path.Combine(root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_session);
        var handshake = Path.Combine(_session, "http.json");
        try
        {
            _job = WindowsProcessJob.Start(binary, handshake, _session);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromSeconds(16));
            try
            {
                while (_port == 0)
                {
                    timeout.Token.ThrowIfCancellationRequested();
                    try
                    {
                        var json = JsonNode.Parse(await File.ReadAllTextAsync(handshake, timeout.Token));
                        if (json?["port"]?.GetValue<int>() is >= 1 and <= 65535 and var port) _port = port;
                    }
                    catch (IOException) { }
                    catch (JsonException) { }
                    if (_port == 0) await Task.Delay(100, timeout.Token);
                }
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw new IOException("陶瓦客户端未在规定时间内返回本机端口。");
            }
            var meta = await RequestAsync("/meta", cancellation);
            if (meta["target_os"]?.GetValue<string>() != "windows")
                throw new IOException("陶瓦客户端的操作系统标识不匹配。");
            if ((await GetStateAsync(cancellation)).State != "waiting")
                throw new IOException("陶瓦正在被其他启动器使用。请先退出对应房间。");
            var query = $"?player={Uri.EscapeDataString(player[..Math.Min(64, player.Length)])}";
            var path = code is null ? "/state/scanning" : "/state/guesting";
            if (code is not null) query += "&room=" + Uri.EscapeDataString(code);
            foreach (var node in await GetPublicNodesAsync(cancellation))
                query += "&public_nodes=" + Uri.EscapeDataString(node);
            await RequestAsync(path + query, cancellation);
            _roomOwned = true;
        }
        catch
        {
            await DisposeAsync();
            throw;
        }
    }

    public static bool IsRoomCode(string code) => code.Length is > 0 and <= 256
        && code.All(ch => !char.IsWhiteSpace(ch) && !char.IsControl(ch));

    public async Task<TerracottaRoom> GetStateAsync(CancellationToken cancellation)
    {
        var state = await RequestAsync("/state", cancellation);
        var address = state["url"]?.GetValue<string>() ?? "";
        try { if (address.Length > 0) address = MinecraftAddress.Parse(address); }
        catch (FormatException) { address = ""; }
        var names = state["profiles"] is JsonArray members
            ? members.OfType<JsonObject>().Take(64).Select(member => member["name"]?.GetValue<string>() ?? "").ToArray()
            : [];
        return new TerracottaRoom(state["state"]?.GetValue<string>() ?? "", state["room"]?.GetValue<string>() ?? "",
            address, state["type"]?.GetValue<int>(), names);
    }

    private async Task<JsonObject> RequestAsync(string path, CancellationToken cancellation)
    {
        var uri = new Uri($"http://127.0.0.1:{_port}{path}");
        var data = await HarborHttp.RequestAsync(HarborHttp.Loopback, uri, 131072, cancellation: cancellation);
        return data.Length == 0 ? new JsonObject() : JsonNode.Parse(data) as JsonObject
            ?? throw new IOException("陶瓦返回的房间状态无法识别。");
    }

    public async ValueTask DisposeAsync()
    {
        if (_roomOwned && _port != 0)
        {
            try { await RequestAsync("/state/ide", CancellationToken.None); }
            catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException or JsonException) { }
        }
        _roomOwned = false;
        _port = 0;
        _job?.Dispose();
        _job = null;
        if (_session is { } session)
        {
            _session = null;
            try { File.Delete(Path.Combine(session, "http.json")); }
            catch (IOException) { }
            try { Directory.Delete(session); }
            catch (IOException) { }
        }
    }

    private static async Task<string[]> GetPublicNodesAsync(CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            var nodeList = await HarborHttp.JsonAsync(HarborHttp.Service, new Uri("https://terracotta.glavo.site/nodes"),
                cancellation: timeout.Token) as JsonArray;
            var china = System.Globalization.RegionInfo.CurrentRegion.TwoLetterISORegionName == "CN";
            return (nodeList ?? []).OfType<JsonObject>().Where(item =>
            {
                var region = item["region"]?.GetValue<string>();
                return string.IsNullOrEmpty(region) || china == region.Equals("CN", StringComparison.OrdinalIgnoreCase);
            }).Select(item => item["url"]?.GetValue<string>() ?? "")
                .Where(address => address.Length <= 240 && Uri.TryCreate(address, UriKind.Absolute, out var node)
                    && node.Scheme is "tcp" or "udp" or "ws" or "wss" && node.UserInfo.Length == 0)
                .Take(24).ToArray();
        }
        catch (Exception error) when (!cancellation.IsCancellationRequested
            && error is HttpRequestException or IOException or JsonException or OperationCanceledException) { return []; }
    }

    private static async Task<string> PrepareBinaryAsync(CancellationToken cancellation)
    {
        var directory = Path.Combine(AppPaths.DataDirectory, "network", "terracotta", "0.4.2-x64");
        Directory.CreateDirectory(directory);
        var binary = Path.Combine(directory, Executable);
        if (FileHashes.All(file => IsVerified(Path.Combine(directory, file.Key), file.Value))) return binary;
        var archive = await HarborHttp.RequestAsync(HarborHttp.Downloads, new Uri(ReleaseUrl), 8_135_914, cancellation: cancellation);
        if (archive.Length != 8_135_914 || !Convert.ToHexString(SHA256.HashData(archive)).Equals(Sha256, StringComparison.OrdinalIgnoreCase))
            throw new IOException("陶瓦发行包校验失败。");
        var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        using var compressed = new GZipStream(new MemoryStream(archive, writable: false), CompressionMode.Decompress);
        using var tar = new TarReader(compressed);
        while (await tar.GetNextEntryAsync(cancellationToken: cancellation) is { } entry)
        {
            if (!FileHashes.TryGetValue(entry.Name, out var hash)
                || entry.EntryType != TarEntryType.RegularFile || entry.DataStream is null
                || entry.Length is < 1 or > 32_000_000 || files.ContainsKey(entry.Name))
                throw new IOException("陶瓦发行包结构异常。");
            using var contents = new MemoryStream();
            await entry.DataStream.CopyToAsync(contents, cancellation);
            var bytes = contents.ToArray();
            if (!Convert.ToHexString(SHA512.HashData(bytes)).Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new IOException("陶瓦包内文件校验失败。");
            files.Add(entry.Name, bytes);
        }
        if (files.Count != FileHashes.Count) throw new IOException("陶瓦发行包缺少文件。");
        foreach (var file in files)
            AccountStore.WriteAtomically(Path.Combine(directory, file.Key), file.Value);
        return binary;
    }

    private static bool IsVerified(string path, string hash)
    {
        if (!File.Exists(path)) return false;
        using var input = File.OpenRead(path);
        return Convert.ToHexString(SHA512.HashData(input)).Equals(hash, StringComparison.OrdinalIgnoreCase);
    }
}

internal sealed record TerracottaRoom(string State, string Code, string Address, int? Exception, string[] Members);
