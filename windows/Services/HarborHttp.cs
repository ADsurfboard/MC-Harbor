using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal static class HarborHttp
{
    public static HttpClient Service { get; } = Create(redirect: false, proxy: true, timeout: 22);
    public static HttpClient Loopback { get; } = Create(redirect: false, proxy: false, timeout: 3);
    public static HttpClient Downloads { get; } = Create(redirect: true, proxy: true, timeout: 180);

    private static HttpClient Create(bool redirect, bool proxy, int timeout)
    {
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = redirect, UseCookies = false, UseProxy = proxy })
        {
            Timeout = TimeSpan.FromSeconds(timeout)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"MC-Harbor-Windows/{AppPaths.Version} (+https://github.com/ADsurfboard/MC-Harbor)");
        return client;
    }

    public static async Task<JsonNode?> JsonAsync(HttpClient client, Uri uri, HttpMethod? method = null, object? payload = null,
        string? token = null, CancellationToken cancellation = default)
    {
        var data = await RequestAsync(client, uri, 8_000_000, method, payload, token, cancellation);
        return JsonNode.Parse(data);
    }

    public static async Task<byte[]> RequestAsync(HttpClient client, Uri uri, int limit, HttpMethod? method = null,
        object? payload = null, string? token = null, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(method ?? HttpMethod.Get, uri);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (payload is not null) request.Content = JsonContent.Create(payload);
        using var timeLimit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeLimit.CancelAfter(client.Timeout);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeLimit.Token);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"服务返回 HTTP {(int)response.StatusCode}。", null, response.StatusCode);
        if (uri.Scheme == "https" && response.RequestMessage?.RequestUri?.Scheme != "https")
            throw new IOException("下载连接未保持 HTTPS。");
        if (response.Content.Headers.ContentLength > limit) throw new IOException("响应超过大小限制。");
        using var input = await response.Content.ReadAsStreamAsync(timeLimit.Token);
        using var output = new MemoryStream();
        var buffer = new byte[65536];
        int count;
        while ((count = await input.ReadAsync(buffer, timeLimit.Token)) > 0)
        {
            if (output.Length + count > limit) throw new IOException("响应超过大小限制。");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}
