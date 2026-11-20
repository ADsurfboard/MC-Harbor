using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal sealed class FriendsClient
{
    public static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    public Uri Origin { get; }
    private readonly string? _token;

    public FriendsClient(Uri origin, string? token)
    {
        Origin = origin;
        _token = token;
    }

    public static Uri ParseEndpoint(string value)
    {
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri)
            || (uri.Scheme != "https" && (uri.Scheme != "http" || !uri.IsLoopback))
            || uri.UserInfo.Length > 0 || uri.AbsolutePath != "/" || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new FormatException("请填写好友服务根地址。公网服务需使用 HTTPS。");
        return new Uri(uri.GetLeftPart(UriPartial.Authority) + "/");
    }

    public Task<JsonNode?> CallAsync(string resource, HttpMethod? method = null, object? body = null, CancellationToken cancellation = default) =>
        HarborHttp.JsonAsync(HarborHttp.Service, new Uri(Origin, "v1/" + resource), method, body, _token, cancellation);

    public async Task<FriendsSnapshot> ReadFriendsAsync(CancellationToken cancellation = default)
    {
        var payload = await CallAsync("friends", cancellation: cancellation);
        var snapshot = payload?.Deserialize<FriendsSnapshot>(JsonOptions)
            ?? throw new IOException("好友服务返回的身份信息无法读取。");
        if (snapshot.Me is null || !Guid.TryParse(snapshot.Me.Id, out _))
            throw new IOException("好友身份无效。");
        return snapshot with
        {
            Friends = Valid(snapshot.Friends),
            Requests = Valid(snapshot.Requests),
            Sent = Valid(snapshot.Sent)
        };

        static FriendIdentity[] Valid(FriendIdentity[]? profiles) =>
            (profiles ?? []).Where(item => item is not null && Guid.TryParse(item.Id, out _)).Take(300).ToArray();
    }

    public async Task<FriendMessage[]> ReadChatAsync(string peer, CancellationToken cancellation = default)
    {
        var result = await CallAsync("messages/" + peer, cancellation: cancellation);
        return (result?.Deserialize<FriendMessage[]>(JsonOptions) ?? []).Where(row => row is not null
            && double.IsFinite(row.Created) && double.IsFinite(row.Expires)
            && row.Expires > DateTimeOffset.UtcNow.ToUnixTimeSeconds()).OrderBy(row => row.Created).TakeLast(100).ToArray();
    }

    public async Task RunSocketAsync(Func<JsonObject, Task> receive, CancellationToken cancellation)
    {
        var health = await HarborHttp.JsonAsync(HarborHttp.Service, new Uri(Origin, "health"), cancellation: cancellation);
        if (health?["realtime"]?.GetValue<bool>() != true)
            throw new NotSupportedException("此服务使用轮询刷新。");
        var address = new UriBuilder(Origin) { Scheme = Origin.Scheme == "https" ? "wss" : "ws", Path = "/v1/live" };
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {_token}");
        socket.Options.SetRequestHeader("User-Agent", "MC-Harbor-Windows/0.1");
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(35);
        using (var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
        {
            connect.CancelAfter(TimeSpan.FromSeconds(15));
            await socket.ConnectAsync(address.Uri, connect.Token);
        }
        var buffer = new byte[4096];
        while (!cancellation.IsCancellationRequested)
        {
            using var message = new MemoryStream();
            WebSocketReceiveResult fragment;
            do
            {
                fragment = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancellation);
                if (fragment.MessageType == WebSocketMessageType.Close) return;
                if (message.Length + fragment.Count > buffer.Length) throw new IOException("好友实时通知过大。");
                message.Write(buffer, 0, fragment.Count);
            } while (!fragment.EndOfMessage);
            if (JsonNode.Parse(message.ToArray()) is JsonObject value) await receive(value);
        }
    }
}

public sealed record FriendIdentity(string Id, string Code, string Name, bool Sharing, string SkinHash, string SkinModel)
{
    public string Label => $"{Name} · {Code}";
}

internal sealed record FriendsSnapshot(FriendIdentity Me, FriendIdentity[] Friends, FriendIdentity[] Requests, FriendIdentity[] Sent);
public sealed record FriendInvitation(string Transport, string Target, string Instance, string Version, string Loader);
public sealed record FriendMessage(string Id, string Sender, string Kind, string Text, FriendInvitation? Invite, double Created, double Expires);
public sealed record FriendConversationRow(FriendMessage Message, string Name)
{
    public string Body => Message.Invite is { } invite
        ? $"联机邀请 · {invite.Target}" + (asText(invite.Version, invite.Loader))
        : Message.Text;
    private static string asText(params string[] details)
    {
        var value = string.Join(" ", details.Where(item => !string.IsNullOrEmpty(item)));
        return value.Length == 0 ? "" : $"\n{value}";
    }
    public string Header => $"{Name}  ·  {DateTimeOffset.FromUnixTimeSeconds((long)Math.Clamp(Message.Created, 0, 253402300799)).ToLocalTime():MM-dd HH:mm}";
}
