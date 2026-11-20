using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private Uri? _friendsOrigin;
    private FriendsClient? _friendsClient;
    private FriendsSnapshot? _friends;
    private CancellationTokenSource? _friendsLife;
    private readonly Dictionary<string, string> _chatDrafts = new();
    private readonly Dictionary<string, (string Body, string Id)> _pendingMessages = new();
    private Dictionary<string, double> _chatReadTimes = new();
    private bool _friendsBusy;
    private bool _updatingFriends;
    private bool _loadingDraft;
    private int _chatSequence;
    private string[] _nextPlayPeers = [];
    private CancellationTokenSource? _playHistoryRequest;
    private FriendPlayHistoryRow[] _visiblePlayHistory = [];

    private void UpdateFriendsPage(bool visible)
    {
        if (!visible)
        {
            _friendsLife?.Cancel();
            _playHistoryRequest?.Cancel();
            return;
        }
        UpdateFriendSummary();
        _ = LoadVisiblePlayHistoryAsync();
        if (_friendsOrigin is null)
        {
            try
            {
                var address = AppPaths.GetPreference("friendsEndpoint");
                if (address.Length == 0)
                    address = JsonNode.Parse(File.ReadAllText(Path.Combine(AppPaths.ApplicationDirectory, "Assets", "Services.json")))?["friends"]?.GetValue<string>() ?? "";
                _friendsOrigin = FriendsClient.ParseEndpoint(address);
            }
            catch (Exception error) { FriendConnectionLabel.Text = error.Message; }
        }
        if (_friendsOrigin is null) return;
        if (_friends is null)
        {
            FriendIdentityLabel.Text = "创建好友身份，或使用原有恢复密钥。";
            _ = FriendsOperationAsync(RestoreSavedFriendsAsync);
        }
        else StartFriendsUpdates();
    }

    private static string FriendSecretKey(Uri address) => "friends:" + address.AbsoluteUri;

    private async Task RestoreSavedFriendsAsync()
    {
        var origin = _friendsOrigin!;
        var token = AppSecrets.Read(FriendSecretKey(origin));
        if (token is null) return;
        await OpenFriendsIdentityAsync(origin, token, save: false);
    }

    private async Task OpenFriendsIdentityAsync(Uri endpoint, string token, bool save)
    {
        if (token.Length is < 32 or > 256 || token.Any(ch => char.IsWhiteSpace(ch) || char.IsControl(ch)))
            throw new FormatException("好友恢复密钥格式无效。");
        var client = new FriendsClient(endpoint, token);
        var snapshot = await client.ReadFriendsAsync();
        if (save) AppSecrets.Save(FriendSecretKey(endpoint), token);
        ClearFriendsIdentity();
        _friendsOrigin = endpoint;
        _friendsClient = client;
        _chatReadTimes = ReadChatTimes(endpoint, snapshot.Me.Id);
        SetFriendsSnapshot(snapshot);
        if (FriendsPage.Visibility == Visibility.Visible) StartFriendsUpdates();
    }

    private void ClearFriendsIdentity()
    {
        _friendsLife?.Cancel();
        _friendsLife = null;
        _friendsClient = null;
        _friends = null;
        ++_chatSequence;
        _chatDrafts.Clear();
        _pendingMessages.Clear();
        _chatReadTimes.Clear();
        FriendsList.ItemsSource = null;
        FriendMessages.ItemsSource = null;
        FriendsCount.Text = "0";
        UpdateFriendSummary();
        if (FriendsPage.Visibility == Visibility.Visible) _ = LoadVisiblePlayHistoryAsync();
        FriendIdentityLabel.Text = "创建好友身份，或使用原有恢复密钥。";
        FriendRequestsButton.Content = "好友申请";
    }

    private async void FriendIdentity_Click(object sender, RoutedEventArgs e)
    {
        await FriendsOperationAsync(async () =>
        {
            var endpoint = new TextBox { Header = "好友服务", Text = _friendsOrigin?.AbsoluteUri ?? "", MinWidth = 320 };
            var name = new TextBox { Header = "新身份昵称", MaxLength = 40 };
            var recovery = new PasswordBox { Header = "恢复密钥", MaxLength = 256 };
            var form = new StackPanel { Spacing = 8, Children = { endpoint, name, recovery } };
            if (_friends is { } current)
            {
                var copy = new Button { Content = "复制我的恢复密钥" };
                copy.Click += (_, _) =>
                {
                    try
                    {
                        if (_friendsOrigin is { } origin && AppSecrets.Read(FriendSecretKey(origin)) is { } token)
                        {
                            CopyText(token);
                            FriendConnectionLabel.Text = "恢复密钥已复制，请妥善保存。";
                        }
                    }
                    catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
                };
                form.Children.Add(copy);
                var sharing = new CheckBox { Content = "向好友共享游玩动态", IsChecked = current.Me.Sharing };
                form.Children.Add(sharing);
                var dialog = FriendDialog("好友身份与服务", form, "保存", "切换或恢复");
                var result = await dialog.ShowAsync();
                if (result == ContentDialogResult.Primary && _friendsClient is { } client
                    && FriendsClient.ParseEndpoint(endpoint.Text) == _friendsOrigin)
                {
                    if ((sharing.IsChecked == true) != current.Me.Sharing)
                    {
                        await client.CallAsync("me", HttpMethod.Put, new { sharing = sharing.IsChecked == true });
                        await RefreshFriendsAsync();
                        if (sharing.IsChecked == true) await UploadLocalPlayHistoryAsync(client);
                    }
                    return;
                }
                if (result == ContentDialogResult.None) return;
                if (result == ContentDialogResult.Primary) { await SwitchEndpointAsync(endpoint.Text); return; }
            }
            else
            {
                var dialog = FriendDialog("好友身份与服务", form, "恢复 / 连接", "创建新身份");
                var result = await dialog.ShowAsync();
                if (result == ContentDialogResult.None) return;
                if (result == ContentDialogResult.Primary && recovery.Password.Length == 0)
                {
                    await SwitchEndpointAsync(endpoint.Text);
                    return;
                }
                if (result == ContentDialogResult.Secondary)
                {
                    var origin = FriendsClient.ParseEndpoint(endpoint.Text);
                    var nickname = name.Text.Trim();
                    if (nickname.Length == 0) throw new IOException("请输入新身份昵称。");
                    var registered = await new FriendsClient(origin, null).CallAsync("register", HttpMethod.Post, new { name = nickname });
                    var token = registered?["token"]?.GetValue<string>() ?? throw new IOException("好友服务未返回恢复密钥。");
                    // Persist the credentials before requesting the profile, so a network failure is recoverable.
                    AppSecrets.Save(FriendSecretKey(origin), token);
                    AppPaths.SetPreference("friendsEndpoint", origin.AbsoluteUri);
                    _friendsOrigin = origin;
                    await OpenFriendsIdentityAsync(origin, token, save: false);
                    return;
                }
            }
            var next = FriendsClient.ParseEndpoint(endpoint.Text);
            if (recovery.Password.Length == 0) { await SwitchEndpointAsync(endpoint.Text); return; }
            await OpenFriendsIdentityAsync(next, recovery.Password.Trim(), save: true);
            AppPaths.SetPreference("friendsEndpoint", next.AbsoluteUri);
        });
    }

    private async Task SwitchEndpointAsync(string address)
    {
        var origin = FriendsClient.ParseEndpoint(address);
        AppPaths.SetPreference("friendsEndpoint", origin.AbsoluteUri);
        ClearFriendsIdentity();
        _friendsOrigin = origin;
        await RestoreSavedFriendsAsync();
    }

    private async void RefreshFriends_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            if (_friendsClient is not { } client) { await RestoreSavedFriendsAsync(); return; }
            await RefreshFriendsAsync();
            if (_friends?.Me.Sharing == true) await UploadLocalPlayHistoryAsync(client);
            await LoadVisiblePlayHistoryAsync();
        });

    private async Task RefreshFriendsAsync()
    {
        var client = RequireFriends();
        var snapshot = await client.ReadFriendsAsync();
        if (_friendsClient == client) SetFriendsSnapshot(snapshot);
        await RefreshFriendInboxAsync(client, CancellationToken.None);
    }

    private void SetFriendsSnapshot(FriendsSnapshot snapshot)
    {
        var selected = (FriendsList.SelectedItem as FriendIdentity)?.Id;
        _friends = snapshot;
        FriendIdentityLabel.Text = $"{snapshot.Me.Name} · 好友码 {snapshot.Me.Code}";
        FriendRequestsButton.Content = $"好友申请 ({snapshot.Requests.Length})";
        UpdateFilteredFriends(selected);
    }

    private void FriendSearch_Changed(object sender, TextChangedEventArgs e)
    {
        if (FriendsList is not null) UpdateFilteredFriends((FriendsList.SelectedItem as FriendIdentity)?.Id);
    }

    private void UpdateFilteredFriends(string? selected)
    {
        var query = FriendSearch.Text.Trim();
        var friends = (_friends?.Friends ?? []).Where(friend =>
            friend.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || friend.Code.Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderBy(friend => friend.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
        var match = friends.FirstOrDefault(friend => friend.Id == selected);
        FriendsCount.Text = (_friends?.Friends.Length ?? 0).ToString();
        _updatingFriends = true;
        FriendsList.ItemsSource = friends;
        FriendsList.SelectedItem = match;
        _updatingFriends = false;
        UpdateFriendSummary();
        if (selected is not null && match is null)
        {
            FriendMessages.ItemsSource = null;
            _loadingDraft = true;
            FriendDraft.Text = "";
            _loadingDraft = false;
            if (FriendsPage.Visibility == Visibility.Visible) _ = LoadVisiblePlayHistoryAsync();
        }
    }

    private async void AddFriend_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            var code = AddFriendCode.Text.Trim().ToUpperInvariant();
            if (code.Length == 0 || !code.All(char.IsAsciiLetterOrDigit)) throw new FormatException("好友码格式无效。");
            await RequireFriends().CallAsync("friends/request", HttpMethod.Post, new { code });
            AddFriendCode.Text = "";
            await RefreshFriendsAsync();
            ShowStatus("已发送好友申请。", InfoBarSeverity.Success);
        });

    private async void FriendRequests_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            var client = RequireFriends();
            var snapshot = await client.ReadFriendsAsync();
            SetFriendsSnapshot(snapshot);
            var choices = new ComboBox { Header = "收到的申请", ItemsSource = snapshot.Requests, DisplayMemberPath = nameof(FriendIdentity.Label),
                SelectedIndex = snapshot.Requests.Length > 0 ? 0 : -1, MinWidth = 240 };
            var sent = new TextBlock { TextWrapping = TextWrapping.Wrap,
                Text = snapshot.Sent.Length == 0 ? "没有待接受的已发申请。" : "已发送：" + string.Join("、", snapshot.Sent.Select(item => item.Name)) };
            var dialog = FriendDialog("好友申请", new StackPanel { Spacing = 8, Children = { choices, sent } }, "接受", "拒绝");
            dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = snapshot.Requests.Length > 0;
            var result = await dialog.ShowAsync();
            if (result == ContentDialogResult.None || choices.SelectedItem is not FriendIdentity selected) return;
            await client.CallAsync("friends/respond", HttpMethod.Post, new { id = selected.Id, accept = result == ContentDialogResult.Primary });
            await RefreshFriendsAsync();
        });

    private void CopyFriendCode_Click(object sender, RoutedEventArgs e)
    {
        if (_friends is { } friends) CopyText(friends.Me.Code);
    }

    private async void FriendsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingFriends) return;
        FriendMessages.ItemsSource = null;
        _loadingDraft = true;
        var friend = FriendsList.SelectedItem as FriendIdentity;
        FriendDraft.Text = friend is null ? "" : _chatDrafts.GetValueOrDefault(friend.Id, "");
        _loadingDraft = false;
        UpdateFriendSummary();
        PlayHistoryFilter.SelectedIndex = 0;
        var history = LoadVisiblePlayHistoryAsync();
        if (friend is not null && _friendsClient is { } client)
        {
            try { await ReadConversationAsync(client, friend, CancellationToken.None); }
            catch (Exception error)
            {
                if (FriendsPage.Visibility == Visibility.Visible && (FriendsList.SelectedItem as FriendIdentity)?.Id == friend.Id)
                    FriendConnectionLabel.Text = "无法读取聊天消息：" + error.Message;
            }
        }
        await history;
    }

    private void MyRecentGames_Click(object sender, RoutedEventArgs e)
    {
        if (FriendsList.SelectedItem is not null) FriendsList.SelectedItem = null;
        else _ = LoadVisiblePlayHistoryAsync();
    }

    private void UpdateFriendSummary()
    {
        var friend = FriendsList.SelectedItem as FriendIdentity;
        SelectedFriendPane.Visibility = VisibleWhen(friend is not null);
        SelectedFriendTitle.Text = friend?.Name ?? "";
        SelectedFriendSharing.Text = friend?.Sharing == true ? "已开启最近游戏共享" : "对方尚未共享最近游戏";
        PlayHistoryHeading.Text = friend is null ? "本机游玩记录" : "好友最近游戏";
        MyRecentGamesButton.Background = friend is null
            ? new Microsoft.UI.Xaml.Media.SolidColorBrush(_glassBorder.Color)
            : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    private async Task LoadVisiblePlayHistoryAsync()
    {
        if (FriendsPage.Visibility != Visibility.Visible) return;
        _playHistoryRequest?.Cancel();
        using var request = new CancellationTokenSource();
        _playHistoryRequest = request;
        var friend = FriendsList.SelectedItem as FriendIdentity;
        _visiblePlayHistory = [];
        ShowPlayHistory(friend is { Sharing: true } ? "正在读取好友最近游戏…" : "暂无游玩记录");
        try
        {
            FriendPlayHistoryRow[] rows;
            if (friend is null)
            {
                var records = await Task.Run(PlayHistoryStore.Read, request.Token);
                rows = records.Take(40).Select(item => FriendPlayHistoryRow.From(item.Instance, item.Version, item.Started, item.Seconds,
                    item.Friends.Length > 0)).ToArray();
            }
            else if (friend.Sharing && _friendsClient is { } client)
            {
                var result = await client.CallAsync("history/" + friend.Id, cancellation: request.Token);
                rows = (result as JsonArray ?? []).OfType<JsonObject>().Take(40)
                    .Select(item => FriendPlayHistoryRow.From(item["instance"]?.ToString() ?? "", item["version"]?.ToString() ?? "",
                        item["started"]?.GetValue<double>() ?? 0, item["seconds"]?.GetValue<double>() ?? 0,
                        item["friends"] is JsonArray { Count: > 0 })).ToArray();
            }
            else rows = [];
            if (request.IsCancellationRequested) return;
            _visiblePlayHistory = rows;
            ShowPlayHistory();
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!request.IsCancellationRequested) ShowPlayHistory("无法读取游玩记录：" + error.Message);
        }
        finally
        {
            if (_playHistoryRequest == request) _playHistoryRequest = null;
        }
    }

    private void PlayHistoryFilter_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (PlayHistoryRows is not null) ShowPlayHistory();
    }

    private void ShowPlayHistory(string empty = "暂无游玩记录")
    {
        var rows = PlayHistoryFilter.SelectedIndex == 1
            ? _visiblePlayHistory.Where(item => item.WithFriends).ToArray() : _visiblePlayHistory;
        PlayHistoryRows.ItemsSource = rows;
        PlayHistoryEmpty.Text = rows.Length == 0 && _visiblePlayHistory.Length > 0 ? "没有与好友游玩的记录" : empty;
        PlayHistoryEmpty.Visibility = VisibleWhen(rows.Length == 0);
    }

    private void FriendDraft_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loadingDraft && FriendsList.SelectedItem is FriendIdentity friend) _chatDrafts[friend.Id] = FriendDraft.Text;
    }

    private async Task ReadConversationAsync(FriendsClient client, FriendIdentity friend, CancellationToken cancellation)
    {
        var sequence = ++_chatSequence;
        var messages = await client.ReadChatAsync(friend.Id, cancellation);
        if (_friendsClient != client || _friends is not { } state || sequence != _chatSequence
            || FriendsPage.Visibility != Visibility.Visible || (FriendsList.SelectedItem as FriendIdentity)?.Id != friend.Id) return;
        var rows = messages.Select(message => new FriendConversationRow(message, message.Sender == state.Me.Id ? state.Me.Name : friend.Name)).ToArray();
        FriendMessages.ItemsSource = rows;
        if (rows.LastOrDefault() is { } newest) FriendMessages.ScrollIntoView(newest);
        if (messages.LastOrDefault() is { } latest)
        {
            _chatReadTimes[friend.Id] = Math.Max(_chatReadTimes.GetValueOrDefault(friend.Id), latest.Created);
            SaveChatTimes();
        }
    }

    private async void SendFriendMessage_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            if (FriendsList.SelectedItem is not FriendIdentity friend) throw new IOException("请选择好友。");
            var message = FriendDraft.Text;
            var value = message.Trim();
            if (value.Length is 0 or > 2000 || value.Any(ch => char.IsControl(ch) && ch is not '\n' and not '\r' and not '\t'))
                throw new IOException("消息须为 1–2000 个字符。");
            await SendFriendAsync(friend, value.Replace("\r\n", "\n").Replace('\r', '\n'), null);
            if (_chatDrafts.GetValueOrDefault(friend.Id) == message) _chatDrafts.Remove(friend.Id);
            if ((FriendsList.SelectedItem as FriendIdentity)?.Id == friend.Id && FriendDraft.Text == message)
                FriendDraft.Text = "";
        });

    private async Task SendFriendAsync(FriendIdentity friend, string text, FriendInvitation? invitation)
    {
        var client = RequireFriends();
        var request = new { kind = invitation is null ? "text" : "invite", text, invite = invitation };
        var body = JsonSerializer.Serialize(request);
        var id = _pendingMessages.GetValueOrDefault(friend.Id) is var pending && pending.Body == body
            ? pending.Id : Guid.NewGuid().ToString();
        _pendingMessages[friend.Id] = (body, id);
        await client.CallAsync("messages/" + friend.Id, HttpMethod.Post, new { id, request.kind, request.text, request.invite });
        _pendingMessages.Remove(friend.Id);
        await ReadConversationAsync(client, friend, CancellationToken.None);
    }

    private async void InviteFriend_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            if (FriendsList.SelectedItem is not FriendIdentity friend) throw new IOException("请选择好友。");
            var hasRoom = _networkRoom is { State: "host-ok", Code.Length: > 0 };
            var address = new TextBox { Header = "服务器地址", Text = _sakuraAddress ?? ServerAddressBox.Text, MaxLength = 260 };
            var dialog = FriendDialog($"邀请 {friend.Name} 联机", address, "发送服务器邀请", hasRoom ? "发送陶瓦房间邀请" : "");
            var result = await dialog.ShowAsync();
            if (result == ContentDialogResult.None) return;
            var target = result == ContentDialogResult.Primary ? MinecraftAddress.Parse(address.Text)
                : _networkRoom?.Code ?? throw new IOException("陶瓦房间已关闭。");
            var instance = MultiplayerInstance.SelectedItem as GameInstance ?? InstanceList.SelectedItem as GameInstance;
            await SendFriendAsync(friend, "一起游玩", new FriendInvitation(
                result == ContentDialogResult.Primary ? "address" : "terracotta", target, instance?.Id ?? "",
                instance?.Version ?? "", instance?.Loader ?? ""));
        });

    private async void OpenFriendInvitation_Click(object sender, RoutedEventArgs e)
    {
        if (FriendMessages.SelectedItem is not FriendConversationRow { Message.Invite: { } invitation } selected) return;
        if (selected.Message.Expires <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
        {
            ShowStatus("这条联机邀请已过期。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            _invitedVersion = invitation.Version;
            _invitedLoader = invitation.Loader;
            if (invitation.Transport == "address") ServerAddressBox.Text = MinecraftAddress.Parse(invitation.Target);
            else if (invitation.Transport == "terracotta" && TerracottaClient.IsRoomCode(invitation.Target)) RoomCodeBox.Text = invitation.Target;
            else throw new FormatException("联机邀请的地址或协议无效。");
            _nextPlayPeers = selected.Message.Sender != _friends?.Me.Id ? [selected.Message.Sender] : [];
            NavigateTo("multiplayer");
            if (invitation.Transport == "terracotta") await StartRoomAsync(invitation.Target);
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private async void FriendHistory_Click(object sender, RoutedEventArgs e) =>
        await FriendsOperationAsync(async () =>
        {
            var client = RequireFriends();
            if (FriendsList.SelectedItem is not FriendIdentity friend) throw new IOException("请选择好友。");
            var body = new StackPanel { Spacing = 9 };
            if (friend.SkinHash is { Length: 64 } hash && hash.All(Uri.IsHexDigit))
            {
                try
                {
                    var uri = new Uri(client.Origin, "v1/skin/" + friend.Id);
                    var token = AppSecrets.Read(FriendSecretKey(client.Origin));
                    var bytes = await HarborHttp.RequestAsync(HarborHttp.Service, uri, 4_000_000, token: token);
                    LittleSkinClient.ValidateSkin(bytes);
                    if (!Convert.ToHexString(SHA256.HashData(bytes)).Equals(hash, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("好友皮肤校验失败。");
                    var path = Path.Combine(AppPaths.DataDirectory, "skins", "friends", hash.ToLowerInvariant() + ".png");
                    AccountStore.WriteAtomically(path, bytes);
                    var open = new Button { Content = "预览好友皮肤" };
                    body.Children.Insert(0, open);
                    open.Tag = path;
                }
                catch (Exception error) { body.Children.Add(new TextBlock { Text = "好友皮肤无法读取：" + error.Message, TextWrapping = TextWrapping.Wrap }); }
            }
            if (body.Children.Count == 0) body.Children.Add(new TextBlock { Text = "未提供共享皮肤。" });
            var share = new Button { Content = "共享我的当前皮肤" };
            var unshare = new Button { Content = "取消我的皮肤共享" };
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { share, unshare } });
            var dialog = FriendDialog(friend.Name, new ScrollViewer { Content = body, MaxHeight = 330 }, "", "移除好友");
            var ownStatus = new TextBlock { TextWrapping = TextWrapping.Wrap };
            body.Children.Add(ownStatus);
            share.Click += async (_, _) =>
            {
                share.IsEnabled = unshare.IsEnabled = false;
                try
                {
                    var profile = await ReadSkinProfileAsync();
                    var path = profile["skinPath"]?.GetValue<string>() ?? throw new IOException("当前账号没有可用的皮肤。");
                    var bytes = await File.ReadAllBytesAsync(path);
                    LittleSkinClient.ValidateSkin(bytes);
                    await client.CallAsync("me", HttpMethod.Put, new { skin = Convert.ToBase64String(bytes),
                        skinModel = profile["model"]?.GetValue<string>() == "slim" ? "slim" : "default" });
                    ownStatus.Text = "已共享当前皮肤。";
                }
                catch (Exception error) { ownStatus.Text = error.Message; }
                finally { share.IsEnabled = unshare.IsEnabled = true; }
            };
            unshare.Click += async (_, _) =>
            {
                share.IsEnabled = unshare.IsEnabled = false;
                try
                {
                    await client.CallAsync("me", HttpMethod.Put, new { clearSkin = true });
                    ownStatus.Text = "已取消皮肤共享。";
                }
                catch (Exception error) { ownStatus.Text = error.Message; }
                finally { share.IsEnabled = unshare.IsEnabled = true; }
            };
            string? preview = null;
            if (body.Children.OfType<Button>().FirstOrDefault() is { Tag: string skin } previewButton)
            {
                previewButton.Click += (_, _) => { preview = skin; dialog.Hide(); };
            }
            var disposition = await dialog.ShowAsync();
            if (preview is not null)
                await ShowSkinPreviewAsync(new JsonObject { ["skinPath"] = preview, ["model"] = friend.SkinModel }, friend.Name);
            if (disposition != ContentDialogResult.Secondary) return;
            var confirm = FriendDialog("移除好友", new TextBlock { Text = $"移除 {friend.Name} 会结束好友关系和聊天。", TextWrapping = TextWrapping.Wrap }, "移除");
            confirm.DefaultButton = ContentDialogButton.Close;
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
            await client.CallAsync("friends/" + friend.Id, HttpMethod.Delete);
            _chatReadTimes.Remove(friend.Id);
            _chatDrafts.Remove(friend.Id);
            await RefreshFriendsAsync();
        });

    private void StartFriendsUpdates()
    {
        if (_friendsClient is not { } client || _friendsLife is { IsCancellationRequested: false }) return;
        var source = new CancellationTokenSource();
        _friendsLife = source;
        _ = RunFriendsUpdatesAsync(client, source);
    }

    private async Task RunFriendsUpdatesAsync(FriendsClient client, CancellationTokenSource source)
    {
        var token = source.Token;
        try
        {
            var polling = PollAsync();
            var delay = 3;
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await client.RunSocketAsync(async item =>
                    {
                        FriendConnectionLabel.Text = "实时消息已连接";
                        delay = 3;
                        if (item["type"]?.GetValue<string>() is "friends" or "deleted")
                            SetFriendsSnapshot(await client.ReadFriendsAsync(token));
                        await RefreshFriendInboxAsync(client, token);
                    }, token);
                }
                catch (NotSupportedException) { break; }
                catch (Exception error) when (error is HttpRequestException or IOException or WebSocketException or OperationCanceledException or JsonException)
                {
                    if (!token.IsCancellationRequested) FriendConnectionLabel.Text = "实时连接暂不可用，定期刷新消息。";
                }
                await Task.Delay(TimeSpan.FromSeconds(delay), token);
                delay = Math.Min(delay * 2, 60);
            }
            await polling;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { if (!token.IsCancellationRequested) FriendConnectionLabel.Text = error.Message; }
        finally
        {
            if (!source.IsCancellationRequested) source.Cancel();
            if (_friendsLife == source) _friendsLife = null;
            source.Dispose();
        }

        async Task PollAsync()
        {
            while (!token.IsCancellationRequested)
            {
                try { await RefreshFriendInboxAsync(client, token); }
                catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException or JsonException) { }
                try { await Task.Delay(TimeSpan.FromSeconds(30), token); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    private async Task RefreshFriendInboxAsync(FriendsClient client, CancellationToken cancellation)
    {
        var result = await client.CallAsync("inbox", cancellation: cancellation);
        if (_friendsClient != client || _friends is not { } current || FriendsPage.Visibility != Visibility.Visible) return;
        var incoming = (result as JsonArray ?? []).OfType<JsonObject>().Where(row =>
            row["sender"]?.GetValue<string>() != current.Me.Id
            && row["created"]?.GetValue<double>() > _chatReadTimes.GetValueOrDefault(row["peer"]?.GetValue<string>() ?? "")).ToArray();
        if (incoming.Length > 0) FriendConnectionLabel.Text = $"{incoming.Length} 个会话有未读消息";
        if (FriendsList.SelectedItem is FriendIdentity friend && incoming.Any(row => row["peer"]?.GetValue<string>() == friend.Id))
            await ReadConversationAsync(client, friend, cancellation);
    }

    private static string ReadTimesPath(Uri origin, string accountId) => Path.Combine(AppPaths.DataDirectory, "social",
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{origin}/{accountId}"))) + ".read.json");

    private static Dictionary<string, double> ReadChatTimes(Uri origin, string accountId)
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, double>>(File.ReadAllBytes(ReadTimesPath(origin, accountId))) ?? new(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    private void SaveChatTimes()
    {
        if (_friendsOrigin is not { } origin || _friends is not { } friends) return;
        try { AccountStore.WriteAtomically(ReadTimesPath(origin, friends.Me.Id), JsonSerializer.SerializeToUtf8Bytes(_chatReadTimes)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private FriendsClient RequireFriends() => _friendsClient ?? throw new IOException("请先创建或恢复好友身份。");

    private async void LocalHistory_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var panel = new StackPanel { Spacing = 8 };
            foreach (var game in PlayHistoryStore.Read().Take(40))
                panel.Children.Add(new TextBlock { TextWrapping = TextWrapping.Wrap,
                    Text = $"{game.Instance} · {game.Version}  ·  {TimeSpan.FromSeconds(Math.Max(0, game.Seconds)):g}" });
            if (panel.Children.Count == 0) panel.Children.Add(new TextBlock { Text = "暂无记录。" });
            await FriendDialog("本机游玩记录", new ScrollViewer { Content = panel, MaxHeight = 420 }, "").ShowAsync();
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private async Task UploadLocalPlayHistoryAsync(FriendsClient client)
    {
        if (_friends is not { Me.Sharing: true } state || _friendsClient != client) return;
        var destination = $"historyUploaded:{client.Origin.AbsoluteUri}:{state.Me.Id}";
        var records = PlayHistoryStore.Read().Where(record => record.Started > 0).Take(100).ToArray();
        if (records.Length == 0) return;
        var head = records[0].Id;
        if (AppPaths.GetPreference(destination) == head) return;
        var allowed = state.Friends.Select(friend => friend.Id).ToHashSet();
        foreach (var batch in records.Chunk(25))
        {
            if (_friendsClient != client || _friends?.Me.Sharing != true) return;
            var entries = batch.Select(record => new
            {
                id = record.Id, instance = record.Instance[..Math.Min(200, record.Instance.Length)],
                version = record.Version[..Math.Min(80, record.Version.Length)], loader = record.Loader[..Math.Min(80, record.Loader.Length)],
                world = record.World[..Math.Min(160, record.World.Length)], started = record.Started,
                seconds = (int)Math.Clamp(record.Seconds, 0, 86400),
                friends = record.Friends.Where(allowed.Contains).ToArray()
            }).ToArray();
            await client.CallAsync("history", HttpMethod.Put, new { entries });
        }
        AppPaths.SetPreference(destination, head);
    }

    private async Task FriendsOperationAsync(Func<Task> operation)
    {
        if (_friendsBusy) { ShowStatus("好友操作正在进行。", InfoBarSeverity.Informational); return; }
        _friendsBusy = true;
        try { await operation(); }
        catch (Exception error) { ShowStatus("好友操作失败：" + error.Message, InfoBarSeverity.Error); }
        finally { _friendsBusy = false; }
    }

    private ContentDialog FriendDialog(string title, UIElement content, string primary, string secondary = "") => new()
    {
        XamlRoot = RootShell.XamlRoot,
        Title = title,
        Content = content,
        PrimaryButtonText = primary,
        SecondaryButtonText = secondary,
        CloseButtonText = "关闭",
        DefaultButton = ContentDialogButton.Primary
    };
}

public sealed record FriendPlayHistoryRow(string Instance, string Summary, string Duration, bool WithFriends)
{
    internal static FriendPlayHistoryRow From(string instance, string version, double started, double seconds, bool withFriends)
    {
        var date = double.IsFinite(started) && started is > 0 and < 253402300799
            ? DateTimeOffset.FromUnixTimeSeconds((long)started).ToLocalTime().ToString("yyyy-MM-dd HH:mm") : "";
        var time = TimeSpan.FromSeconds(double.IsFinite(seconds) ? Math.Clamp(seconds, 0, 31536000) : 0);
        var duration = time.TotalHours >= 1 ? $"{(int)time.TotalHours} 小时 {time.Minutes} 分钟" : $"{time.Minutes} 分钟";
        return new FriendPlayHistoryRow(instance, string.Join(" · ", new[] { version, date }.Where(value => value.Length > 0)),
            duration, withFriends);
    }
}
