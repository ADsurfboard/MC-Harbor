using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private bool _skinDialogOpen;
    private readonly Dictionary<string, ImageSource> _accountAvatars = new(StringComparer.Ordinal);
    private Task<MinecraftSkin>? _defaultSkin;
    private MinecraftSkin? _loadedAccountSkin;
    private string _loadedSkinModel = "default";
    private string? _draftSkinPath;
    private bool _applyingAccountSkin;
    private bool _canApplyAccountSkin;
    private string _accountSkinModel = "default";
    private string _accountSkinMotion = "none";
    private long _accountSkinPreviewRequest;

    private void UpdateAccountPresentation(StoredAccount? account)
    {
        var name = account?.Name ?? AppPaths.OfflineUsername;
        var kind = account?.KindLabel ?? "离线账号";
        SelectedAccountName.Text = name;
        SelectedAccountKind.Text = kind;
        CurrentAccountName.Text = name;
        CurrentAccountKind.Text = account?.RequiresReauth == true ? "需要重新登录" : kind;
        CancelAccountSkinPreview();
        _loadedAccountSkin = null;
        _loadedSkinModel = "default";
        _draftSkinPath = null;
        _canApplyAccountSkin = account is null || (account.Kind == "offline" && !account.RequiresReauth);
        CurrentAccountAvatar.Source = account is null ? null : _accountAvatars.GetValueOrDefault(account.Id);
        AccountSkinUuid.Text = account?.Uuid ?? "";
        AccountSkinPreviewStatus.Visibility = Visibility.Visible;
        AccountSkinPreviewStatus.Text = account?.RequiresReauth == true
            ? "重新登录后可读取此账号的皮肤。" : "正在载入皮肤…";
        _accountSkinModel = "default";
        _accountSkinMotion = "none";
        UpdateSkinOptionButtons();
        UpdateAccountSkinOptions();
        UpdateAccountSkinDraft();
    }

    private void CancelAccountSkinPreview()
    {
        _accountSkinPreviewRequest++;
        AccountSkinViewport.ShowSkin(null, slim: false);
    }

    private async Task LoadSelectedAccountSkinPreviewAsync(bool refresh = false)
    {
        if (AccountWorkspace.Visibility != Visibility.Visible) return;
        var request = ++_accountSkinPreviewRequest;
        var selected = (AccountsList.SelectedItem as AccountListEntry)?.Account;
        try
        {
            if (_defaultSkin is null || _defaultSkin.IsFaulted)
                _defaultSkin = MinecraftSkinLoader.LoadAsync(Path.Combine(AppPaths.ApplicationDirectory, "Assets", "Skins", "wide", "steve.png"));
            var fallback = await _defaultSkin;
            if (request != _accountSkinPreviewRequest) return;
            if (_loadedAccountSkin is null)
            {
                _loadedAccountSkin = fallback;
                AccountSkinViewport.ShowSkin(fallback, _accountSkinModel == "slim");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
            or System.Runtime.InteropServices.COMException) { }

        if (request != _accountSkinPreviewRequest) return;
        if (selected?.RequiresReauth == true)
        {
            AccountSkinPreviewStatus.Text = "重新登录后可读取此账号的皮肤。";
            AccountSkinPreviewStatus.Visibility = Visibility.Visible;
            return;
        }
        try
        {
            var profile = await ReadSkinProfileAsync(refresh);
            var skinPath = profile["skinPath"]?.GetValue<string>()
                ?? throw new IOException("当前账号没有可用的皮肤文件。");
            var skin = await MinecraftSkinLoader.LoadAsync(skinPath, profile["capePath"]?.GetValue<string>());
            if (request != _accountSkinPreviewRequest) return;
            var useOriginalModel = _accountSkinModel == _loadedSkinModel;
            _loadedAccountSkin = skin;
            _loadedSkinModel = profile["model"]?.GetValue<string>() == "slim" ? "slim" : "default";
            if (useOriginalModel && _draftSkinPath is null) _accountSkinModel = _loadedSkinModel;
            _canApplyAccountSkin = selected is null || selected.Kind == "offline"
                || profile["canUpload"]?.GetValue<bool>() == true;
            ApplySelectedAccountAvatar(skin, selected);
            AccountSkinUuid.Text = profile["uuid"]?.GetValue<string>() ?? AccountSkinUuid.Text;
            if (_draftSkinPath is null) AccountSkinViewport.ShowSkin(skin, _accountSkinModel == "slim");
            AccountSkinPreviewStatus.Visibility = Visibility.Collapsed;
            UpdateSkinOptionButtons();
            UpdateAccountSkinOptions();
            UpdateAccountSkinDraft();
        }
        catch (Exception error)
        {
            if (request != _accountSkinPreviewRequest) return;
            AccountSkinPreviewStatus.Text = refresh ? "皮肤刷新失败。" : _defaultSkin?.IsCompletedSuccessfully == true
                ? "暂未读取到账号皮肤，正在显示默认角色。" : "皮肤预览暂不可用。";
            AccountSkinPreviewStatus.Visibility = Visibility.Visible;
            if (refresh) ShowStatus("无法刷新皮肤：" + error.Message, InfoBarSeverity.Warning);
        }
    }

    private void RefreshSkin_Click(object sender, RoutedEventArgs e)
    {
        if (AccountWorkspace.Visibility != Visibility.Visible) return;
        AccountSkinPreviewStatus.Text = "正在刷新皮肤…";
        AccountSkinPreviewStatus.Visibility = Visibility.Visible;
        _ = LoadSelectedAccountSkinPreviewAsync(refresh: true);
    }

    private void SkinMotion_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string motion }) return;
        _accountSkinMotion = motion;
        UpdateSkinOptionButtons();
        UpdateAccountSkinOptions();
    }

    private void SkinModel_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string model }) return;
        _accountSkinModel = model;
        UpdateSkinOptionButtons();
        UpdateAccountSkinOptions();
        UpdateAccountSkinDraft();
    }

    private void UpdateAccountSkinDraft()
    {
        var pending = _draftSkinPath is not null;
        SkinDraftStatus.Text = pending && !_canApplyAccountSkin ? "此账号仅支持预览导入的皮肤。" : "预览尚未应用";
        SkinDraftStatus.Visibility = pending ? Visibility.Visible : Visibility.Collapsed;
        SkinDraftActions.Visibility = pending ? Visibility.Visible : Visibility.Collapsed;
        ApplyDraftSkinButton.IsEnabled = pending && _canApplyAccountSkin && !_applyingAccountSkin;
        ImportSkinButton.IsEnabled = !_applyingAccountSkin;
        CancelSkinDraftButton.IsEnabled = !_applyingAccountSkin;
    }

    private async void ImportSkin_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var accountId = AppPaths.SelectedAccountId;
            var file = await PickFileAsync(".png");
            if (file is null || _closing || _applyingAccountSkin || accountId != AppPaths.SelectedAccountId
                || AccountWorkspace.Visibility != Visibility.Visible) return;
            var skin = await MinecraftSkinLoader.LoadAsync(file.Path);
            if (_closing || _applyingAccountSkin || accountId != AppPaths.SelectedAccountId
                || AccountWorkspace.Visibility != Visibility.Visible) return;
            if (skin.Texture.Width != 64 || skin.Texture.Height is not (32 or 64))
                throw new IOException("请选择 64×64 或 64×32 的 Minecraft PNG 皮肤。");
            _draftSkinPath = file.Path;
            AccountSkinViewport.ShowSkin(skin with { Cape = _loadedAccountSkin?.Cape }, _accountSkinModel == "slim");
            AccountSkinPreviewStatus.Visibility = Visibility.Collapsed;
            UpdateAccountSkinDraft();
        }
        catch (Exception error) { ShowStatus("无法预览皮肤：" + error.Message, InfoBarSeverity.Warning); }
    }

    private void CancelSkinDraft_Click(object sender, RoutedEventArgs e)
    {
        _draftSkinPath = null;
        _accountSkinModel = _loadedSkinModel;
        AccountSkinViewport.ShowSkin(_loadedAccountSkin, _accountSkinModel == "slim");
        UpdateSkinOptionButtons();
        UpdateAccountSkinOptions();
        UpdateAccountSkinDraft();
    }

    private async void ApplySkinDraft_Click(object sender, RoutedEventArgs e)
    {
        if (_draftSkinPath is not { } path || !_canApplyAccountSkin || _applyingAccountSkin) return;
        _applyingAccountSkin = true;
        UpdateAccountSkinDraft();
        try { await ApplySkinAsync(path, _accountSkinModel == "slim"); }
        catch (Exception error) { ShowStatus("更换皮肤失败：" + error.Message, InfoBarSeverity.Error); }
        finally
        {
            _applyingAccountSkin = false;
            UpdateAccountSkinDraft();
        }
    }

    private void UpdateAccountSkinOptions()
    {
        AccountSkinViewport.SetOptions(_accountSkinModel == "slim", _accountSkinMotion,
            AccountWorkspace.Visibility == Visibility.Visible && _chromeActive && AllowsAmbientAnimation());
    }

    private void UpdateSkinOptionButtons()
    {
        var accent = _chromeHighContrast ? _uiSettings.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.Highlight)
            : Color.FromArgb(255, 192, 225, 222);
        var onAccent = _chromeHighContrast ? _uiSettings.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.HighlightText)
            : Color.FromArgb(255, 24, 42, 43);
        var foreground = _chromeHighContrast ? _uiSettings.GetColorValue(global::Windows.UI.ViewManagement.UIColorType.Foreground)
            : _darkAppearance ? Color.FromArgb(255, 238, 245, 244) : Color.FromArgb(255, 23, 38, 37);
        var selected = new SolidColorBrush(accent);
        var normal = new SolidColorBrush(foreground);
        var selectedText = new SolidColorBrush(onAccent);
        var clear = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        SkinMotionTrack.Background = SkinModelTrack.Background = new SolidColorBrush(_darkAppearance
            ? Color.FromArgb(28, 255, 255, 255) : Color.FromArgb(28, 32, 50, 50));
        SetSelection(SkinStillButton, _accountSkinMotion == "none");
        SetSelection(SkinRotateButton, _accountSkinMotion == "rotate");
        SetSelection(SkinWalkButton, _accountSkinMotion == "walk");
        SetSelection(SkinDefaultModelButton, _accountSkinModel == "default");
        SetSelection(SkinSlimModelButton, _accountSkinModel == "slim");

        void SetSelection(Button button, bool active)
        {
            button.Background = active ? selected : clear;
            button.Foreground = active ? selectedText : normal;
        }
    }

    private void ApplySelectedAccountAvatar(MinecraftSkin skin, StoredAccount? selected)
    {
        var source = MinecraftSkinLoader.CreateAvatar(skin.Texture);
        CurrentAccountAvatar.Source = source;
        if (selected is null) return;
        _accountAvatars[selected.Id] = source;
        if (AccountsList.SelectedItem is AccountListEntry row && row.Account.Id == selected.Id) row.Avatar = source;
    }

    private async void ImportMacMigration_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var file = await PickFileAsync(".json");
            if (file is null) return;
            var password = new PasswordBox { Header = "Mac 导出时设置的迁移口令", MaxLength = 512, MinWidth = 280 };
            var dialog = FriendDialog("导入 Mac 登录迁移包",
                new StackPanel { Spacing = 8, Children =
                {
                    password,
                    new TextBlock { Text = "口令只用于解密。导入后会转存到这台 Windows 电脑的当前用户凭据中。",
                        TextWrapping = TextWrapping.Wrap, MaxWidth = 380 }
                } }, "解密并导入");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var passphrase = password.Password;
            password.Password = "";
            if (passphrase.Length < 12) throw new IOException("迁移口令至少需要 12 个字符。");
            var info = new FileInfo(file.Path);
            if (info.Length is 0 or > 16_000_000) throw new IOException("迁移包大小超出限制。");
            var bytes = await File.ReadAllBytesAsync(file.Path);
            JsonObject payload;
            try { payload = await Task.Run(() => AccountMigrationBundle.Decrypt(bytes, passphrase)); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            passphrase = "";

            var existing = AccountStore.ReadAll().ToDictionary(account => account.Id, StringComparer.Ordinal);
            var imported = 0;
            var skipped = 0;
            foreach (var value in payload["accounts"]?.AsArray() ?? [])
            {
                if (value is not JsonObject account) continue;
                var id = account["metadata"]?["id"]?.GetValue<string>() ?? "";
                if (existing.TryGetValue(id, out var saved) && !saved.RequiresReauth)
                {
                    skipped++;
                    continue;
                }
                var stored = AccountStore.Save(account);
                existing[stored.Id] = stored;
                imported++;
            }
            RefreshAccounts();
            var message = imported == 0
                ? "迁移包中的账号已经导入。"
                : $"已将 {imported} 个 Mac 登录状态保存到此 Windows 用户。";
            if (skipped > 0) message += $" {skipped} 个现有账号保持不变。";
            ShowStatus(message, InfoBarSeverity.Success);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException
            or JsonException or InvalidOperationException)
        {
            ShowStatus("Mac 登录迁移失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void ExternalLogin_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var server = new TextBox { Header = "认证服务器", PlaceholderText = "https://littleskin.cn/api/yggdrasil" };
            var username = new TextBox { Header = "账号" };
            var password = new PasswordBox { Header = "密码" };
            var form = new StackPanel { Spacing = 9, MinWidth = 340, Children = { server, username, password } };
            var dialog = FriendDialog("外置认证登录", form, "登录");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var raw = server.Text.Trim();
            if (!raw.Contains("://", StringComparison.Ordinal)) raw = "https://" + raw;
            if (!Uri.TryCreate(raw, UriKind.Absolute, out var origin)
                || (origin.Scheme != "https" && (origin.Scheme != "http" || !origin.IsLoopback))
                || origin.UserInfo.Length > 0 || origin.Query.Length > 0 || origin.Fragment.Length > 0)
                throw new FormatException("请输入有效的 HTTPS 认证地址。");
            var arguments = new Dictionary<string, object?>
            {
                ["server"] = origin.AbsoluteUri, ["username"] = username.Text.Trim(), ["password"] = password.Password
            };
            password.Password = "";
            var bridge = RequireBridge();
            ShowStatus("正在连接外置认证服务…", InfoBarSeverity.Informational);
            var result = await bridge.InvokeAsync("externalLogin", arguments);
            if (result["profiles"] is JsonArray choices)
            {
                var profiles = choices.OfType<JsonObject>().Select(row =>
                    new RoleChoice(row["id"]!.GetValue<string>(), row["name"]!.GetValue<string>())).ToArray();
                var picker = new ComboBox
                {
                    Header = "Minecraft 角色", DisplayMemberPath = nameof(RoleChoice.Name),
                    ItemsSource = profiles, SelectedIndex = profiles.Length == 0 ? -1 : 0, MinWidth = 250
                };
                if (await FriendDialog("选择角色", picker, "使用此角色").ShowAsync() != ContentDialogResult.Primary
                    || picker.SelectedItem is not RoleChoice profile) return;
                arguments["profile"] = profile.Id;
                result = await bridge.InvokeAsync("externalLogin", arguments);
            }
            arguments.Remove("password");
            var account = AccountStore.Save(result);
            AccountStore.Select(account.Id);
            RefreshAccounts();
            ShowStatus($"外置账号 {account.Name} 已保存。", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus("外置登录失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async Task<Dictionary<string, object?>> ProfileArgumentsAsync()
    {
        if (AppPaths.SelectedAccountId is not { Length: > 0 } id)
        {
            var result = await RequireBridge().InvokeAsync("offlineAccount", new Dictionary<string, object?>
            {
                ["username"] = AppPaths.OfflineUsername
            });
            return new Dictionary<string, object?> { ["accountType"] = "offline", ["account"] = result };
        }
        var account = AccountStore.ReadAll().FirstOrDefault(item => item.Id == id);
        if (account?.RequiresReauth != false || AccountStore.LoadPayload(id) is not { } payload)
            throw new IOException("请先重新登录当前账号。");
        return new Dictionary<string, object?> { ["accountType"] = account.Kind, ["account"] = payload };
    }

    private async void OpenSkin_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var profile = await ReadSkinProfileAsync();
            await ShowSkinPreviewAsync(profile, profile["name"]?.GetValue<string>() ?? "Minecraft 皮肤");
        }
        catch (Exception error) { ShowStatus("无法预览皮肤：" + error.Message, InfoBarSeverity.Error); }
    }

    private async Task<JsonObject> ReadSkinProfileAsync(bool refresh = false)
    {
        var arguments = await ProfileArgumentsAsync();
        arguments["refresh"] = refresh;
        return await RequireBridge().InvokeAsync("profile", arguments);
    }

    private async void ApplySkin_Click(object sender, RoutedEventArgs e)
    {
        if (AccountWorkspace.Visibility == Visibility.Visible)
        {
            ImportSkin_Click(sender, e);
            return;
        }
        try
        {
            var file = await PickFileAsync(".png");
            if (file is null) return;
            var options = new ComboBox { Header = "角色模型", ItemsSource = new[] { "标准", "纤细" }, SelectedIndex = 0, MinWidth = 220 };
            if (await FriendDialog("更换当前账号皮肤", options, "应用").ShowAsync() != ContentDialogResult.Primary) return;
            await ApplySkinAsync(file.Path, options.SelectedIndex == 1);
        }
        catch (Exception error) { ShowStatus("更换皮肤失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async Task ApplySkinAsync(string path, bool slim)
    {
        var selectedId = AppPaths.SelectedAccountId;
        var account = await ProfileArgumentsAsync();
        account["skinFile"] = path;
        account["slim"] = slim;
        JsonObject? newest = null;
        var result = await RequireBridge().InvokeAsync("applySkin", account, message =>
        {
            if (message["event"]?.GetValue<string>() == "accountUpdated") newest = message["data"] as JsonObject;
        });
        if (newest is not null)
        {
            var stored = AccountStore.Save(newest);
            if (AppPaths.SelectedAccountId == selectedId)
            {
                AccountStore.Select(stored.Id);
                RefreshAccounts();
            }
        }
        else if (AppPaths.SelectedAccountId == selectedId) RefreshAccounts();
        ShowStatus($"已更换 {result["name"]} 的皮肤。", InfoBarSeverity.Success);
    }

    private async Task ShowSkinPreviewAsync(JsonObject profile, string title)
    {
        if (_skinDialogOpen) return;
        _skinDialogOpen = true;
        try
        {
            var path = profile["skinPath"]?.GetValue<string>() ?? throw new IOException("未找到皮肤文件。");
            var skin = await MinecraftSkinLoader.LoadAsync(path, profile["capePath"]?.GetValue<string>());
            if (_closing) return;
            var slim = profile["model"]?.GetValue<string>() == "slim";
            var viewport = new Controls.MinecraftSkinViewport { Height = 310, Width = 320 };
            viewport.ShowSkin(skin, slim);
            viewport.SetOptions(slim, "none", false);
            var dialog = FriendDialog(title, viewport, "");
            await dialog.ShowAsync();
        }
        finally
        {
            _skinDialogOpen = false;
        }
    }

    private async void LittleSkin_Click(object sender, RoutedEventArgs e)
    {
        try { await ShowLittleSkinAsync(); }
        catch (Exception error) { ShowStatus("皮肤库打开失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async Task ShowLittleSkinAsync()
    {
        var query = new TextBox { PlaceholderText = "皮肤名称或作者", Width = 180, MaxLength = 100 };
        var sort = new ComboBox { ItemsSource = new[] { "最多收藏", "最新上传" }, SelectedIndex = 0 };
        var rows = new ListView { DisplayMemberPath = nameof(LittleSkinEntry.Label), MinHeight = 110, MaxHeight = 270 };
        var search = new Button { Content = "搜索" };
        var previous = new Button { Content = "上一页", IsEnabled = false };
        var next = new Button { Content = "下一页", IsEnabled = false };
        var favorites = new Button { Content = "查看收藏" };
        var toggle = new Button { Content = "收藏 / 取消收藏" };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { query, sort, search } },
                rows,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { previous, next, favorites, toggle } },
                status
            }
        };
        var dialog = FriendDialog("LittleSkin 皮肤库", body, "应用所选", "预览所选");
        var page = 1;
        var loading = false;
        var closed = false;
        var showingFavorites = false;
        dialog.Closed += (_, _) => closed = true;

        async Task LoadAsync(int requestedPage)
        {
            if (loading || closed) return;
            loading = true;
            try
            {
                var result = await LittleSkinClient.SearchAsync(query.Text.Trim(), requestedPage, sort.SelectedIndex == 0);
                if (closed) return;
                showingFavorites = false;
                rows.ItemsSource = result.Rows;
                page = requestedPage;
                previous.IsEnabled = page > 1;
                next.IsEnabled = page < result.LastPage;
                status.Text = $"第 {page} / {result.LastPage} 页";
            }
            catch (Exception error) { status.Text = error.Message; }
            finally { loading = false; }
        }

        void ShowFavorites()
        {
            showingFavorites = true;
            rows.ItemsSource = LittleSkinClient.ReadFavorites();
            previous.IsEnabled = next.IsEnabled = false;
            status.Text = "已收藏的皮肤";
        }

        search.Click += async (_, _) => await LoadAsync(1);
        next.Click += async (_, _) => await LoadAsync(page + 1);
        previous.Click += async (_, _) => await LoadAsync(Math.Max(1, page - 1));
        favorites.Click += (_, _) => { try { ShowFavorites(); } catch (Exception error) { status.Text = error.Message; } };
        toggle.Click += (_, _) =>
        {
            try
            {
                if (rows.SelectedItem is not LittleSkinEntry selection) return;
                var added = LittleSkinClient.ToggleFavorite(selection);
                if (showingFavorites) ShowFavorites();
                status.Text = added ? "已收藏。" : "已取消收藏。";
            }
            catch (Exception error) { status.Text = error.Message; }
        };
        rows.SelectionChanged += (_, _) =>
            dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = rows.SelectedItem is LittleSkinEntry { Hd: false };
        dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = false;
        var show = dialog.ShowAsync();
        _ = LoadAsync(1);
        var disposition = await show;
        if (disposition == ContentDialogResult.None || rows.SelectedItem is not LittleSkinEntry entry) return;
        var file = await LittleSkinClient.GetSkinAsync(entry);
        if (disposition == ContentDialogResult.Primary) await ApplySkinAsync(file, entry.Slim);
        else
            await ShowSkinPreviewAsync(new JsonObject { ["skinPath"] = file, ["model"] = entry.Slim ? "slim" : "default" }, entry.Name);
    }

    private sealed record RoleChoice(string Id, string Name);
}
