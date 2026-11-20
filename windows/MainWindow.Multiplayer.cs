using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private readonly SakuraClient _sakura = new();
    private CancellationTokenSource? _roomCancellation;
    private CancellationTokenSource? _sakuraCancellation;
    private Task? _roomTask;
    private Task? _sakuraTask;
    private SakuraState? _sakuraState;
    private TerracottaRoom? _networkRoom;
    private string? _sakuraAddress;
    private string? _invitedVersion;
    private string? _invitedLoader;

    private void PrepareMultiplayer()
    {
        var previous = (MultiplayerInstance.SelectedItem as GameInstance)?.Id;
        MultiplayerInstance.ItemsSource = _instances.ToArray();
        MultiplayerInstance.SelectedItem = FindInvitedInstance() ?? _instances.FirstOrDefault(item => item.Id == previous)
            ?? _instances.FirstOrDefault();
    }

    private GameInstance? FindInvitedInstance() => _instances.FirstOrDefault(item =>
        !string.IsNullOrEmpty(_invitedVersion) && item.Version == _invitedVersion
        && (string.IsNullOrEmpty(_invitedLoader) || item.Loader.Equals(_invitedLoader, StringComparison.OrdinalIgnoreCase)));

    private async void JoinServer_Click(object sender, RoutedEventArgs e)
    {
        if (MultiplayerInstance.SelectedItem is not GameInstance instance)
        {
            ShowStatus("请选择已安装的 Minecraft 实例。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            var address = MinecraftAddress.Parse(ServerAddressBox.Text);
            if (!string.IsNullOrEmpty(_invitedVersion)
                && (instance.Version != _invitedVersion || (!string.IsNullOrEmpty(_invitedLoader)
                    && !instance.Loader.Equals(_invitedLoader, StringComparison.OrdinalIgnoreCase))))
            {
                var choose = new ContentDialog
                {
                    XamlRoot = RootShell.XamlRoot,
                    Title = "实例版本与邀请不一致",
                    Content = $"邀请要求 Minecraft {_invitedVersion} {_invitedLoader}。是否使用 {instance.Id} 启动？",
                    PrimaryButtonText = "继续",
                    CloseButtonText = "返回",
                    DefaultButton = ContentDialogButton.Close
                };
                if (await choose.ShowAsync() != ContentDialogResult.Primary) return;
            }
            if (!MinecraftAddress.HasQuickPlay(instance.Version))
            {
                CopyText(address);
                var dialog = new ContentDialog
                {
                    XamlRoot = RootShell.XamlRoot, Title = "在游戏内加入",
                    Content = $"服务器地址已复制。启动后可在多人游戏中使用直连。\n{address}",
                    PrimaryButtonText = "启动 Minecraft", CloseButtonText = "返回",
                    DefaultButton = ContentDialogButton.Primary
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                await LaunchAsync(instance);
            }
            else await LaunchAsync(instance, address);
        }
        catch (Exception error) { ShowStatus("无法加入服务器：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void HostRoom_Click(object sender, RoutedEventArgs e) => await StartRoomAsync(null);
    private async void JoinRoom_Click(object sender, RoutedEventArgs e) => await StartRoomAsync(RoomCodeBox.Text.Trim());
    private void StopRoom_Click(object sender, RoutedEventArgs e) => _roomCancellation?.Cancel();

    private Task StartRoomAsync(string? code)
    {
        if (_roomTask is { IsCompleted: false }) return _roomTask;
        _roomTask = RunRoomAsync(code);
        return _roomTask;
    }

    private async Task RunRoomAsync(string? code)
    {
        using var cancellation = new CancellationTokenSource();
        _roomCancellation = cancellation;
        HostRoomButton.IsEnabled = JoinRoomButton.IsEnabled = false;
        StopRoomButton.IsEnabled = true;
        try
        {
            RoomStatus.Text = "正在检查陶瓦客户端…";
            var name = AccountStore.ReadAll().FirstOrDefault(item => item.Id == AppPaths.SelectedAccountId)?.Name
                ?? AppPaths.OfflineUsername;
            await using var client = new TerracottaClient();
            await client.OpenRoomAsync(code, name, cancellation.Token);
            var failures = 0;
            while (true)
            {
                try
                {
                    var room = await client.GetStateAsync(cancellation.Token);
                    _networkRoom = room;
                    failures = 0;
                    RoomStatus.Text = room.State switch
                    {
                        "host-scanning" => "等待游戏开放局域网…",
                        "host-starting" => "正在创建房间…",
                        "host-ok" => $"房间码：{room.Code}",
                        "guest-starting" or "guest-connecting" => "正在连接房主…",
                        "guest-ok" => "已加入陶瓦房间。可在 Minecraft 多人游戏中选择局域网房间。",
                        "exception" => $"房间出现连接错误（{room.Exception}）。",
                        _ => "等待房间状态…"
                    };
                    if (room.Members.Length > 0) RoomStatus.Text += "\n成员：" + string.Join("、", room.Members);
                    if (room.State == "host-ok" && room.Code.Length > 0) RoomCodeBox.Text = room.Code;
                    if (room.State == "guest-ok" && room.Address.Length > 0) ServerAddressBox.Text = room.Address;
                    if (room.State == "exception") break;
                }
                catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException)
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (++failures >= 4) throw new IOException("陶瓦本机连接已中断。", error);
                }
                await Task.Delay(TimeSpan.FromSeconds(1.5), cancellation.Token);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { RoomStatus.Text = "已退出房间。"; }
        catch (Exception error) { RoomStatus.Text = "陶瓦连接失败：" + error.Message; }
        finally
        {
            _networkRoom = null;
            _roomCancellation = null;
            HostRoomButton.IsEnabled = JoinRoomButton.IsEnabled = true;
            StopRoomButton.IsEnabled = false;
        }
    }

    private async void LoadSakura_Click(object sender, RoutedEventArgs e)
    {
        var token = SakuraToken.Password;
        SakuraToken.Password = "";
        await StartSakuraOperationAsync(async cancellation =>
        {
            _sakuraState = await _sakura.ConnectAsync(token, cancellation);
            UpdateSakuraOptions(_sakuraState);
            SakuraStatus.Text = $"已连接 {_sakuraState.Name}。";
        }, active: false);
    }

    private async void CreateSakura_Click(object sender, RoutedEventArgs e)
    {
        if (SakuraNodes.SelectedItem is not SakuraNode node || !double.IsFinite(SakuraPort.Value)
            || SakuraPort.Value != Math.Truncate(SakuraPort.Value))
        {
            SakuraStatus.Text = "请选择节点并填写游戏显示的局域网端口。";
            return;
        }
        var port = (int)SakuraPort.Value;
        await StartSakuraOperationAsync(async cancellation =>
        {
            _sakuraState = await _sakura.CreateAsync(node, port, cancellation);
            UpdateSakuraOptions(_sakuraState);
            SakuraStatus.Text = "TCP 隧道已创建。";
        }, active: false);
    }

    private async void StartSakura_Click(object sender, RoutedEventArgs e)
    {
        if (SakuraTunnels.SelectedItem is not SakuraTunnel tunnel
            || _sakuraState?.Nodes.FirstOrDefault(node => node.Id == tunnel.Node) is not { } node)
        {
            SakuraStatus.Text = "请先读取并选择一个本机 TCP 隧道。";
            return;
        }
        await StartSakuraOperationAsync(async cancellation =>
        {
            SakuraStatus.Text = "正在连接隧道…";
            await _sakura.RunAsync(tunnel, node, address =>
            {
                _sakuraAddress = address;
                SakuraStatus.Text = address is null ? "连接中断，等待重新连接…" : $"已连接：{address}";
            }, cancellation);
            SakuraStatus.Text = "隧道已退出。";
        }, active: true);
    }

    private void StopSakura_Click(object sender, RoutedEventArgs e) => _sakuraCancellation?.Cancel();

    private Task StartSakuraOperationAsync(Func<CancellationToken, Task> operation, bool active)
    {
        if (_sakuraTask is { IsCompleted: false }) return _sakuraTask;
        _sakuraTask = RunSakuraOperationAsync(operation, active);
        return _sakuraTask;
    }

    private async Task RunSakuraOperationAsync(Func<CancellationToken, Task> operation, bool active)
    {
        using var cancellation = new CancellationTokenSource();
        _sakuraCancellation = cancellation;
        LoadSakuraButton.IsEnabled = CreateSakuraButton.IsEnabled = StartSakuraButton.IsEnabled = false;
        StopSakuraButton.IsEnabled = active;
        try { await operation(cancellation.Token); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { SakuraStatus.Text = "Sakura 隧道已停止。"; }
        catch (Exception error) { SakuraStatus.Text = "Sakura Frp 操作失败：" + error.Message; }
        finally
        {
            _sakuraAddress = null;
            _sakuraCancellation = null;
            LoadSakuraButton.IsEnabled = CreateSakuraButton.IsEnabled = StartSakuraButton.IsEnabled = true;
            StopSakuraButton.IsEnabled = false;
        }
    }

    private void UpdateSakuraOptions(SakuraState state)
    {
        SakuraNodes.ItemsSource = state.Nodes;
        SakuraNodes.SelectedIndex = state.Nodes.Length == 0 ? -1 : 0;
        SakuraTunnels.ItemsSource = state.Tunnels;
        SakuraTunnels.SelectedIndex = state.Tunnels.Length == 0 ? -1 : 0;
    }

    private static void CopyText(string text)
    {
        var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
        data.SetText(text);
        global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
    }
}
