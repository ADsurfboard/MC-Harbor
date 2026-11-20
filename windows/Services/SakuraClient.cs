using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal sealed class SakuraClient : IAsyncDisposable
{
    private const string Credential = "sakura-frp";
    private const string Endpoint = "https://api.natfrp.com/v4/";
    private Process? _process;
    private string? _configuration;

    public async Task<SakuraState> ConnectAsync(string supplied, CancellationToken cancellation)
    {
        var token = supplied.Trim();
        if (token.Length == 0) token = GetToken();
        ValidateToken(token);
        var state = await ReadStateAsync(token, cancellation);
        AppSecrets.Save(Credential, token);
        return state;
    }

    public async Task<SakuraState> CreateAsync(SakuraNode node, int port, CancellationToken cancellation)
    {
        if (!node.Available || port is < 1 or > 65535) throw new FormatException("请选择可用节点并填写有效的局域网端口。");
        var token = GetToken();
        await QueryAsync("tunnels", token, new { name = $"MC-Harbor-{port}", type = "tcp", node = node.Id, local_ip = "127.0.0.1", local_port = port }, cancellation);
        return await ReadStateAsync(token, cancellation);
    }

    public async Task RunAsync(SakuraTunnel tunnel, SakuraNode node, Action<string?> state, CancellationToken cancellation)
    {
        if (!tunnel.Available || node.Id != tunnel.Node || !node.Available)
            throw new IOException("请选择正常的本机 TCP 隧道。");
        if (_process is not null) throw new InvalidOperationException("已有 Sakura 隧道正在运行。");
        var token = GetToken();
        var (exe, version) = await PrepareBinaryAsync(cancellation);
        var configuration = await HarborHttp.RequestAsync(HarborHttp.Service, new Uri(Endpoint + "tunnel/config"),
            1_000_000, HttpMethod.Post, new { query = tunnel.Id.ToString(System.Globalization.CultureInfo.InvariantCulture), frpc = version },
            token, cancellation);
        var text = Encoding.UTF8.GetString(configuration);
        if (string.IsNullOrWhiteSpace(text) || text.TrimStart().StartsWith('{'))
            throw new IOException("Sakura Frp 返回的隧道配置无效。");
        var folder = Path.Combine(AppPaths.DataDirectory, "network", "sakura-sessions");
        var user = WindowsIdentity.GetCurrent().User ?? throw new IOException("无法确定当前 Windows 用户。");
        var session = new DirectoryInfo(Path.Combine(folder, Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(folder);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        session.Create(security);
        _configuration = Path.Combine(session.FullName, text.Contains("[common]", StringComparison.Ordinal) ? "session.ini" : "session.toml");
        try
        {
            await File.WriteAllBytesAsync(_configuration, configuration, cancellation);
            var start = new ProcessStartInfo(exe)
            {
                WorkingDirectory = session.FullName, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add(_configuration);
            _process = Process.Start(start) ?? throw new IOException("Sakura Frp 未启动。");
            var process = _process;
            var ready = false;
            async Task ReadAsync(StreamReader reader)
            {
                while (await reader.ReadLineAsync(cancellation) is { } line)
                {
                    if (line.Contains("start proxy success", StringComparison.OrdinalIgnoreCase))
                    {
                        ready = true;
                        state(MinecraftAddress.Parse($"{node.Host}:{tunnel.Remote}"));
                    }
                    else if (ready && (line.Contains("connection closed", StringComparison.OrdinalIgnoreCase)
                        || line.Contains("reconnect", StringComparison.OrdinalIgnoreCase)))
                    {
                        ready = false;
                        state(null);
                    }
                }
            }
            await Task.WhenAll(ReadAsync(process.StandardOutput), ReadAsync(process.StandardError), process.WaitForExitAsync(cancellation));
            if (process.ExitCode != 0) throw new IOException($"Sakura Frp 已退出，退出码 {process.ExitCode}。");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(configuration);
            await DisposeAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        var process = _process;
        _process = null;
        if (process is not null)
        {
            using (process)
            {
                try
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync();
                }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            }
        }
        if (_configuration is { } configuration)
        {
            _configuration = null;
            try
            {
                File.Delete(configuration);
                Directory.Delete(Path.GetDirectoryName(configuration)!);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private static string GetToken() => AppSecrets.Read(Credential)
        ?? throw new IOException("请输入 Sakura Frp 访问密钥。");

    private static void ValidateToken(string token)
    {
        if (token.Length is 0 or > 512 || token.Any(ch => char.IsWhiteSpace(ch) || char.IsControl(ch)))
            throw new FormatException("Sakura Frp 访问密钥格式无效。");
    }

    private static Task<JsonNode?> QueryAsync(string path, string? token, object? payload, CancellationToken cancellation) =>
        HarborHttp.JsonAsync(HarborHttp.Service, new Uri(Endpoint + path),
            payload is null ? HttpMethod.Get : HttpMethod.Post, payload, token, cancellation);

    private static async Task<SakuraState> ReadStateAsync(string token, CancellationToken cancellation)
    {
        var user = QueryAsync("user/info", token, null, cancellation);
        var nodes = QueryAsync("nodes", token, null, cancellation);
        var tunnels = QueryAsync("tunnels", token, null, cancellation);
        await Task.WhenAll(user, nodes, tunnels);
        if (user.Result is not JsonObject info || info["name"] is null || info["ban"] is not null
            || nodes.Result is not JsonObject nodeRows || tunnels.Result is not JsonArray tunnelRows)
            throw new IOException("Sakura Frp 账号或节点列表无法读取。");
        var available = nodeRows.Where(item => int.TryParse(item.Key, out _) && item.Value is JsonObject)
            .Select(item => new SakuraNode(int.Parse(item.Key), ReadString(item.Value, "name"),
                ReadString(item.Value, "host"), item.Value?["flag"]?.GetValue<int>() ?? 0))
            .Where(item => item.Available).OrderBy(item => item.Name).ToArray();
        var local = tunnelRows.OfType<JsonObject>().Select(item => new SakuraTunnel(
            item["id"]?.GetValue<int>() ?? 0, ReadString(item, "name"), item["node"]?.GetValue<int>() ?? 0,
            ReadString(item, "type"), ReadString(item, "local_ip"), item["local_port"]?.GetValue<int>() ?? 0,
            ReadString(item, "remote"), item["status"]?.GetValue<int>() ?? 0))
            .Where(item => item.Available && available.Any(node => node.Id == item.Node)).ToArray();
        return new SakuraState(ReadString(info, "name"), available, local);
    }

    private static string ReadString(JsonNode? node, string name) =>
        node?[name] is JsonValue value ? value.ToString() : "";

    private static async Task<(string Path, string Version)> PrepareBinaryAsync(CancellationToken cancellation)
    {
        var meta = await QueryAsync("system/clients", null, null, cancellation);
        var frpc = meta?["frpc"];
        var architecture = WindowsPlatform.NativeArchitecture;
        var arch = frpc?["archs"]?[architecture == "arm64" ? "windows_arm64" : "windows_amd64"];
        var version = ReadString(frpc, "ver");
        var hash = ReadString(arch, "hash");
        if (version.Length == 0 || hash.Length != 32 || !hash.All(Uri.IsHexDigit)
            || arch?["size"]?.GetValue<int>() is not (> 0 and < 50_000_000 and var size)
            || !Uri.TryCreate(ReadString(arch, "url"), UriKind.Absolute, out var url) || url.Scheme != "https" || url.UserInfo.Length > 0)
            throw new IOException($"Sakura Frp 官方未返回可用的 {architecture} 客户端。");
        var folder = Path.Combine(AppPaths.DataDirectory, "network", "sakura");
        var target = Path.Combine(folder, $"frpc-{hash.ToLowerInvariant()}.exe");
        if (!File.Exists(target) || !Matches(await File.ReadAllBytesAsync(target, cancellation)))
        {
            var bytes = await HarborHttp.RequestAsync(HarborHttp.Downloads, url, size, cancellation: cancellation);
            if (!Matches(bytes)) throw new IOException("Sakura Frp 客户端校验失败。");
            AccountStore.WriteAtomically(target, bytes);
        }
        return (target, version);

        bool Matches(byte[] bytes)
        {
            if (bytes.Length != size || bytes.Length < 0x40 || bytes[0] != 'M' || bytes[1] != 'Z') return false;
            var pe = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(0x3c, 4));
            return pe >= 0 && pe <= bytes.Length - 6
                && BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(pe, 4)) == 0x4550
                && BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(pe + 4, 2)) == WindowsPlatform.MachineFor(architecture)
                && Convert.ToHexString(MD5.HashData(bytes)).Equals(hash, StringComparison.OrdinalIgnoreCase);
        }
    }
}

public sealed record SakuraNode(int Id, string Name, string Host, int Flag)
{
    public bool Available => (Flag & 4) != 0 && (Flag & 512) == 0 && Host.Length > 0;
}

public sealed record SakuraTunnel(int Id, string Name, int Node, string Type, string LocalIp, int LocalPort, string Remote, int Status)
{
    public bool Available => Id > 0 && Type == "tcp" && Status == 0 && LocalPort is >= 1 and <= 65535
        && LocalIp is "127.0.0.1" or "localhost" or "::1"
        && int.TryParse(Remote, out var port) && port is >= 1 and <= 65535;
    public string Label => $"{Name} · 本机 {LocalPort}";
}

internal sealed record SakuraState(string Name, SakuraNode[] Nodes, SakuraTunnel[] Tunnels);
