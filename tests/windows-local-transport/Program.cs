using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using MCHarbor.Windows.Services;

// Exercise the real production client factory against disposable loopback endpoints.
// No model, account, game, external service or user data is opened.
await using var proxy = new Endpoint("200 OK", "synthetic-proxy");
await using var destination = new Endpoint("200 OK", "synthetic-local");
await using var redirect = new Endpoint("302 Found", "", "Location: " + proxy.Address + "\r\n");
var variables = new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY" };
var previous = variables.ToDictionary(name => name, Environment.GetEnvironmentVariable);
try
{
    foreach (var name in variables)
        Environment.SetEnvironmentVariable(name, name == "NO_PROXY" ? "" : proxy.Address);

    using (var control = new HttpClient { Timeout = TimeSpan.FromSeconds(5) })
    using (var response = await control.PostAsync(destination.Address + "v1/chat/completions", new StringContent("synthetic-source")))
    {
        Check(await response.Content.ReadAsStringAsync() == "synthetic-proxy"
            && proxy.Bodies.Contains("synthetic-source") && destination.Count == 0,
            "Default .NET client forwards to configured proxy (control)");
    }

    using (var local = IndexTranslationWorker.CreateLoopbackClient(destination.Port))
    {
        local.Timeout = TimeSpan.FromSeconds(5);
        using var response = await local.PostAsync("v1/chat/completions", new StringContent("synthetic-source"));
        Check(await response.Content.ReadAsStringAsync() == "synthetic-local"
            && destination.Bodies.Contains("synthetic-source") && proxy.Count == 1,
            "Production local client bypasses configured proxy");
    }

    using (var local = IndexTranslationWorker.CreateLoopbackClient(redirect.Port))
    {
        local.Timeout = TimeSpan.FromSeconds(5);
        using var response = await local.GetAsync("health");
        Check(response.StatusCode == HttpStatusCode.Found && proxy.Count == 1,
            "Production local client rejects redirects");
    }
    Console.WriteLine("3 local transport checks passed.");
}
finally
{
    foreach (var item in previous) Environment.SetEnvironmentVariable(item.Key, item.Value);
}

static void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + name);
    Console.WriteLine("PASS: " + name);
}

internal sealed class Endpoint : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new(TimeSpan.FromSeconds(30));
    private readonly Task _serve;
    private readonly byte[] _response;
    private int _count;
    internal ConcurrentQueue<string> Bodies { get; } = new();
    internal int Count => Volatile.Read(ref _count);
    internal int Port { get; }
    internal string Address => $"http://127.0.0.1:{Port}/";

    internal Endpoint(string status, string body, string extraHeaders = "")
    {
        _response = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Length: {body.Length}\r\n"
            + extraHeaders + "Connection: close\r\n\r\n" + body);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _serve = ServeAsync();
    }

    private async Task ServeAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                using var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
                var length = 0;
                while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 } line)
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                        length = int.Parse(line[15..].Trim(), System.Globalization.CultureInfo.InvariantCulture);
                if (length is < 0 or > 4096) throw new InvalidDataException("Invalid synthetic request.");
                var body = new char[length];
                if (length > 0 && await reader.ReadBlockAsync(body.AsMemory(), _stop.Token) != length)
                    throw new EndOfStreamException();
                Bodies.Enqueue(new string(body));
                Interlocked.Increment(ref _count);
                await stream.WriteAsync(_response, _stop.Token);
            }
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (SocketException) when (_stop.IsCancellationRequested) { }
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        _listener.Stop();
        await _serve;
        _stop.Dispose();
    }
}

namespace MCHarbor.Windows.Services
{
    // Dependency required to compile the real workers; these paths are never accessed.
    internal static class AppPaths
    {
        internal static string DataDirectory => throw new InvalidOperationException("No player data in transport checks.");
        internal static string ApplicationDirectory => throw new InvalidOperationException("No application data in transport checks.");
        internal static string BackendDirectory => throw new InvalidOperationException("No backend data in transport checks.");
    }
}
