using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Windows.Graphics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MCHarbor.Windows;

public sealed partial class MainWindow : Window
{
    private readonly List<GameInstance> _instances = [];
    private readonly HashSet<string> _gameDirectoryWrites = new(StringComparer.OrdinalIgnoreCase);
    private GameInstance? _activeModsInstance;
    private Process? _gameProcess;
    private Task? _launchTask;
    private string? _stopFile;
    private string? _runningGameRunDirectory;
    private bool _allowClose;
    private bool _closePromptOpen;
    private bool _closing;
    private bool _updatingAccounts;
    private bool _chromeActive = true;
    private bool _chromePointerOver;
    private bool _chromeButtonFocused;
    private bool _chromeHighContrast;
    private bool _initialWindowSizeSet;
    private bool? _accountCardsStacked;
    private HarborWindowFrame? _windowFrame;
    private int _resourceRequest;
    private string? _lastNavigationTag;

    public MainWindow()
    {
        InitializeComponent();
        RootShell.Tag = this;
        Title = "MC Harbor";
        InitializeWindowChrome();
        RuntimeGameDirectory.Text = AppPaths.GameRoot;
        DownloadTaskList.ItemsSource = _downloadJobs;
        ResetLanguageWorkspace();
        InitializeSidebar();
        InitializeAppearance();
        NavigateTo("games");
        AppWindow.Closing += AppWindow_Closing;
    }

    private void InitializeWindowChrome()
    {
        var applicationIcon = Path.Combine(AppPaths.ApplicationDirectory, "Assets", "App.ico");
        if (File.Exists(applicationIcon)) AppWindow.SetIcon(applicationIcon);

        if (AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);

        var hwnd = WindowNative.GetWindowHandle(this);
        _windowFrame = new HarborWindowFrame(hwnd);
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            const uint cornerPreference = 33;
            const uint borderColor = 34;
            var roundCorners = 2;
            _ = DwmSetWindowAttribute(hwnd, cornerPreference, in roundCorners, sizeof(int));
            var noBorderColor = unchecked((int)0xFFFFFFFE);
            _ = DwmSetWindowAttribute(hwnd, borderColor, in noBorderColor, sizeof(int));
        }
        Activated += WindowChrome_Activated;
        AppWindow.Changed += WindowChrome_Changed;
        UpdateWindowChromeState();
    }

    private void RootShell_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateFeaturedGameWidth();
        QueueBackdropRefresh();
    }

    private void WindowChrome_Changed(AppWindow sender, AppWindowChangedEventArgs args) =>
        DispatcherQueue.TryEnqueue(UpdateWindowChromeState);

    private void WindowChrome_Activated(object sender, WindowActivatedEventArgs args)
    {
        _chromeActive = args.WindowActivationState != WindowActivationState.Deactivated;
        WindowChromeOverlay.Opacity = _chromeActive ? 1 : 0.78;
        UpdateChromeGlyphs();
    }

    private void UpdateWindowChromeState()
    {
        var maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        ChromeMaximizeGlyph.Text = maximized ? "◱" : "□";
        var label = maximized ? "还原" : "最大化";
        ToolTipService.SetToolTip(ChromeMaximizeButton, label);
        AutomationProperties.SetName(ChromeMaximizeButton, label + " MC Harbor");
    }

    private void ChromeDrag_PointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(RootShell).Properties.IsLeftButtonPressed) return;
        const uint nonClientLeftButtonDown = 0x00A1;
        const int captionHit = 2;
        e.Handled = true;
        var hwnd = WindowNative.GetWindowHandle(this);
        ReleaseCapture();
        _ = SendMessage(hwnd, nonClientLeftButtonDown, captionHit, 0);
    }

    private void ChromeDrag_DoubleTapped(object sender, Microsoft.UI.Xaml.Input.DoubleTappedRoutedEventArgs e) =>
        ChromeMaximize_Click(sender, e);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, uint attribute, in int value, int size);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll", EntryPoint = "SendMessageW")]
    private static extern nint SendMessage(nint hwnd, uint message, nint wparam, nint lparam);

    private void ChromeButtons_PointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e) =>
        SetChromePointerState(true);

    private void ChromeButtons_PointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e) =>
        SetChromePointerState(false);

    private void ChromeButton_Focused(object sender, RoutedEventArgs e)
    {
        _chromeButtonFocused = true;
        UpdateChromeGlyphs();
    }

    private void ChromeButton_LostFocus(object sender, RoutedEventArgs e)
    {
        _chromeButtonFocused = false;
        UpdateChromeGlyphs();
    }

    private void SetChromePointerState(bool pointerOver)
    {
        _chromePointerOver = pointerOver;
        UpdateChromeGlyphs();
    }

    private void UpdateChromeGlyphs()
    {
        var opacity = (_chromeHighContrast || _chromePointerOver || _chromeButtonFocused) && _chromeActive ? 1d : 0d;
        ChromeCloseGlyph.Opacity = opacity;
        ChromeMinimizeGlyph.Opacity = opacity;
        ChromeMaximizeGlyph.Opacity = opacity;
        var dim = _chromeActive ? 1d : 0.62d;
        ChromeCloseDot.Opacity = dim;
        ChromeMinimizeDot.Opacity = dim;
        ChromeMaximizeDot.Opacity = dim;
    }

    private void ChromeClose_Click(object sender, RoutedEventArgs e) => Close();

    private void ChromeMinimize_Click(object sender, RoutedEventArgs e)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Minimize();
    }

    private void ChromeMaximize_Click(object sender, RoutedEventArgs e)
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        if (presenter.State == OverlappedPresenterState.Maximized) presenter.Restore();
        else presenter.Maximize();
        UpdateWindowChromeState();
    }

    private void ShowAccounts_Click(object sender, RoutedEventArgs e) => NavigateTo("accounts");

    private void RefreshAccountPage_Click(object sender, RoutedEventArgs e)
    {
        RefreshAccounts(refreshSkin: true);
    }

    private void AccountWorkspace_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width < 1) return;
        var stacked = e.NewSize.Width < 660;
        ImportHmclTopButton.Visibility = e.NewSize.Width < 375 ? Visibility.Collapsed : Visibility.Visible;
        AccountLoginActions.Orientation = e.NewSize.Width < 350 ? Orientation.Vertical : Orientation.Horizontal;
        if (_accountCardsStacked != stacked)
        {
            _accountCardsStacked = stacked;
            AccountCardsLayout.ColumnDefinitions[0].Width = stacked ? new GridLength(1, GridUnitType.Star) : new GridLength(240);
            AccountCardsLayout.ColumnDefinitions[1].Width = stacked ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
            AccountCardsLayout.RowDefinitions[1].Height = stacked ? GridLength.Auto : new GridLength(0);
            AccountCardsLayout.ColumnSpacing = stacked ? 0 : 22;
            AccountCardsLayout.RowSpacing = stacked ? 14 : 12;
            Grid.SetRow(AccountDetailsCard, stacked ? 1 : 0);
            Grid.SetColumn(AccountDetailsCard, stacked ? 0 : 1);
            Grid.SetColumnSpan(AccountLoginActions, stacked ? 1 : 2);
        }
        QueueGlassCardsRefresh();
    }

    private async void OfflineAccountQuickAdd_Click(object sender, RoutedEventArgs e)
    {
        var username = new TextBox
        {
            Header = "离线昵称",
            PlaceholderText = "3–16 位英文、数字或下划线",
            Text = AppPaths.OfflineUsername,
            MaxLength = 16,
            MinWidth = 280
        };
        var dialog = FriendDialog("添加离线账号", username, "使用此账号");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        UseOfflineAccount(username.Text.Trim());
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        if (_appearanceWindowLoaded) return;
        _appearanceWindowLoaded = true;
        if (!_initialWindowSizeSet && RootShell.XamlRoot is { } root)
        {
            var scale = root.RasterizationScale;
            var bounds = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
            AppWindow.Resize(new SizeInt32(Math.Min(bounds.Width, (int)Math.Round(1280 * scale)),
                Math.Min(bounds.Height, (int)Math.Round(747 * scale))));
            _initialWindowSizeSet = true;
        }
        if (AccountWorkspace.Visibility != Visibility.Visible) RefreshAccounts();
        QueueBackdropRefresh();
        await InitializeWallpaperAsync();
        await RefreshInstancesAsync();
        _libraryLoaded = true;
        while (_activationInstances.TryDequeue(out var id))
        {
            await LaunchFromShortcutAsync(id);
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshInstancesAsync();

    private async Task RefreshInstancesAsync()
    {
        try
        {
            var result = await Task.Run(() => InstanceScanner.Scan(AppPaths.GameRoot));
            _instances.Clear();
            _instances.AddRange(result.Select(instance => AppPaths.GetPreference(RunDirectoryPreferenceKey(instance.Directory)) is { Length: > 0 } path
                ? instance with { RunDirectory = path } : instance));
            ApplyGameFilter();
            RuntimeGameDirectory.Text = AppPaths.GameRoot;
            if (_activeModsInstance is { } current)
            {
                _activeModsInstance = _instances.FirstOrDefault(instance => instance.Directory == current.Directory);
                if (_activeModsInstance is null && IsInstancePage(_lastNavigationTag)) NavigateTo("games");
                else if (IsInstancePage(_lastNavigationTag)) UpdateWorkspaceHeader();
            }
            if (CatalogPage.Visibility == Visibility.Visible) PrepareCatalog();
            if (ModFoldersPage.Visibility == Visibility.Visible) UpdateModFolderTargets();
            if (result.Count == 0)
                ShowStatus("在此游戏目录中没有找到已安装的 Minecraft 实例。", InfoBarSeverity.Informational);
            else
                CloseStatus();
        }
        catch (Exception error)
        {
            ShowStatus(error.Message, InfoBarSeverity.Error);
        }
    }

    private async void ChooseRoot_Click(object sender, RoutedEventArgs e)
    {
        if (_launchTask is { IsCompleted: false } || _catalogTask is { IsCompleted: false }
            || _instanceDownloadTask is { IsCompleted: false } || _languageBusy)
        {
            ShowStatus("请等当前游戏或资源任务结束后再切换游戏目录。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            var selected = await PickFolderAsync();
            if (selected is null) return;
            AppPaths.SetGameRoot(selected.Path);
            _activeModsInstance = null;
            if (IsInstancePage(_lastNavigationTag)) NavigateTo("games");
            await RefreshInstancesAsync();
            if (MultiplayerPage.Visibility == Visibility.Visible) PrepareMultiplayer();
            if (CatalogPage.Visibility == Visibility.Visible) PrepareCatalog();
            if (ModFoldersPage.Visibility == Visibility.Visible) RefreshModFolders();
            if (LocalizationWorkspace.Visibility == Visibility.Visible) PrepareLanguageWorkspace();
        }
        catch (Exception error) { ShowStatus("游戏目录无法设置：" + error.Message, InfoBarSeverity.Error); }
    }

    private async Task<global::Windows.Storage.StorageFolder?> PickFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return await picker.PickSingleFolderAsync();
    }

    private async Task<global::Windows.Storage.StorageFile?> PickFileAsync(params string[] extensions)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        foreach (var extension in extensions) picker.FileTypeFilter.Add(extension);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return await picker.PickSingleFileAsync();
    }

    private async void Launch_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is { } instance) await LaunchAsync(instance);
    }

    private void ManageMods_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        _activeModsInstance = instance;
        _resourceCategory = instance.Loader == "vanilla" ? "saves" : "mods";
        _instanceResources = [];
        ResourceQuery.Text = "";
        if (_lastNavigationTag == "collections")
        {
            UpdateWorkspaceHeader();
            _ = LoadResourcesAsync();
        }
        else NavigateTo("collections");
    }

    private void OpenInstanceLocalization_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        _activeModsInstance = instance;
        if (_lastNavigationTag == "localization")
        {
            UpdateWorkspaceHeader();
            PrepareLanguageWorkspace();
        }
        else NavigateTo("localization");
    }

    private async void Repair_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        var java = JavaRuntimeLocator.FindLauncherJava();
        if (java is null)
        {
            ShowStatus("修复实例需要 Java 21 运行时。", InfoBarSeverity.Error);
            return;
        }
        ShowStatus($"正在校验并修复 {instance.Id}…", InfoBarSeverity.Informational);
        try
        {
            await new BridgeClient(java).InvokeAsync("repair", new Dictionary<string, object?>
            {
                ["id"] = instance.Id
            }, HandleBridgeEvent);
            ShowStatus($"实例 {instance.Id} 已完成文件校验。", InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            ShowStatus("修复实例失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void ImportModpack_Click(object sender, RoutedEventArgs e)
    {
        var file = await PickFileAsync(".zip", ".mrpack");
        if (file is null) return;
        var suggestedName = Path.GetFileNameWithoutExtension(file.Name);
        var nameBox = new TextBox
        {
            Header = "新实例名称",
            Text = suggestedName,
            PlaceholderText = "例如：整合包实例"
        };
        var dialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = "导入整合包",
            Content = nameBox,
            PrimaryButtonText = "导入并安装",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var name = nameBox.Text.Trim();
        if (!IsSafeInstanceName(name))
        {
            ShowStatus("请填写有效的实例名称。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            await StartInstanceDownloadAsync(RequireBridge(), "import", new Dictionary<string, object?>
            {
                ["file"] = file.Path, ["name"] = name
            }, $"导入整合包 {file.Name}", result => $"整合包已安装为 {result["id"]?.GetValue<string>() ?? name}。");
        }
        catch (Exception error) { ShowStatus("导入整合包失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void ExportPack_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        var folder = await PickFolderAsync();
        if (folder is null) return;
        var filenameBox = new TextBox
        {
            Header = "新 ZIP 文件名",
            Text = $"{instance.Id}-MultiMC.zip",
            PlaceholderText = "必须是一个尚不存在的文件名"
        };
        var nameDialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = "导出位置",
            Content = filenameBox,
            PrimaryButtonText = "继续",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await nameDialog.ShowAsync() != ContentDialogResult.Primary) return;
        var filename = filenameBox.Text.Trim();
        if (filename.Length == 0) return;
        if (!filename.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) filename += ".zip";
        if (!string.Equals(Path.GetFileName(filename), filename, StringComparison.Ordinal)
            || filename.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            ShowStatus("文件名只能包含一个文件名，不能输入目录路径。", InfoBarSeverity.Warning);
            return;
        }
        var outputPath = Path.Combine(folder.Path, filename);
        if (File.Exists(outputPath) || Directory.Exists(outputPath))
        {
            ShowStatus("目标文件已存在。为保护原文件，请选择新名称。", InfoBarSeverity.Warning);
            return;
        }
        var choices = new (string Id, string Label, bool Selected)[]
        {
            ("mods", "模组", true),
            ("config", "配置与默认配置", true),
            ("options", "游戏选项", true),
            ("servers", "服务器列表", false),
            ("resourcepacks", "资源包", true),
            ("shaderpacks", "光影", true),
            ("scripts", "脚本与书籍", true),
            ("saves", "世界存档", false)
        };
        var checks = choices.Select(choice => new CheckBox
        {
            Content = choice.Label,
            Tag = choice.Id,
            IsChecked = choice.Selected
        }).ToArray();
        var contentsPanel = new StackPanel { Spacing = 4 };
        foreach (var check in checks) contentsPanel.Children.Add(check);
        var dialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = "选择导出内容",
            Content = contentsPanel,
            PrimaryButtonText = "导出 ZIP",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var contents = checks.Where(check => check.IsChecked == true)
            .Select(check => check.Tag?.ToString() ?? "")
            .Where(value => value.Length > 0)
            .ToArray();
        if (contents.Length == 0)
        {
            ShowStatus("至少选择一类内容再导出。", InfoBarSeverity.Warning);
            return;
        }
        var java = JavaRuntimeLocator.FindLauncherJava();
        if (java is null)
        {
            ShowStatus("导出整合包需要 Java 21 运行时。", InfoBarSeverity.Error);
            return;
        }
        ShowStatus($"正在导出 {instance.Id}…", InfoBarSeverity.Informational);
        try
        {
            var result = await new BridgeClient(java).InvokeAsync("export", new Dictionary<string, object?>
            {
                ["id"] = instance.Id,
                ["output"] = outputPath,
                ["contents"] = contents
            }, HandleBridgeEvent);
            ShowStatus("整合包已导出：" + (result["path"]?.GetValue<string>() ?? outputPath), InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            ShowStatus("导出整合包失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void ImportResource_Click(object sender, RoutedEventArgs e)
    {
        var instance = _activeModsInstance;
        if (instance is null) return;
        var kind = _resourceCategory;
        if (kind is not ("mods" or "resourcepacks" or "shaderpacks" or "saves")) return;
        try
        {
            var extension = kind == "mods" ? ".jar" : ".zip";
            var file = await PickFileAsync(extension);
            if (file is null) return;
            if (!Path.GetExtension(file.Name).Equals(extension, StringComparison.OrdinalIgnoreCase))
                throw new IOException("所选文件格式与资源类型不匹配。");
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                if (kind == "saves")
                {
                    EnsureOrdinaryDirectory(Path.Combine(run, "saves"));
                    await RequireBridge().InvokeAsync("installWorld", new Dictionary<string, object?>
                    {
                        ["file"] = file.Path,
                        ["name"] = Path.GetFileNameWithoutExtension(file.Name),
                        ["runDirectory"] = instance.RunDirectory
                    });
                }
                else
                {
                    await CopyResourceAsync(file.Path, run, kind);
                }
            }
            finally { _gameDirectoryWrites.Remove(run); }
            if (_activeModsInstance == instance) await LoadResourcesAsync();
            ShowStatus($"已导入 {file.Name}。", InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            ShowStatus("导入资源失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async Task LoadResourcesAsync()
    {
        if (_activeModsInstance is not { } instance || ResourcesList.Visibility != Visibility.Visible) return;
        var sequence = ++_resourceRequest;
        _instanceResources = [];
        UpdateResourceRows();
        var java = JavaRuntimeLocator.FindLauncherJava();
        if (java is null)
        {
            ShowStatus("读取实例资源需要 Java 21 运行时。", InfoBarSeverity.Error);
            return;
        }
        ShowStatus($"正在读取 {instance.Id} 的实例资源…", InfoBarSeverity.Informational);
        try
        {
            var result = await new BridgeClient(java).InvokeAsync("resources", new Dictionary<string, object?>
            {
                ["id"] = instance.Id,
                ["runDirectory"] = instance.RunDirectory
            });
            if (sequence != _resourceRequest || _activeModsInstance != instance || ResourcesList.Visibility != Visibility.Visible) return;
            var resources = new List<InstanceResource>();
            if (result["resources"] is JsonArray rows)
            {
                foreach (var row in rows.OfType<JsonObject>())
                {
                    var path = row["path"]?.GetValue<string>() ?? "";
                    if (path.Length == 0) continue;
                    resources.Add(new InstanceResource(
                        path,
                        row["name"]?.GetValue<string>() ?? Path.GetFileName(path),
                        row["kind"]?.GetValue<string>() ?? "",
                        row["enabled"]?.GetValue<bool>() ?? false,
                        row["languageFiles"]?.GetValue<int>() ?? 0));
                }
            }
            _instanceResources = resources.ToArray();
            UpdateResourceRows();
            CloseStatus();
        }
        catch (Exception error)
        {
            if (sequence == _resourceRequest && _activeModsInstance == instance && ResourcesList.Visibility == Visibility.Visible)
                ShowStatus("读取实例资源失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void ToggleResource_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox toggle || toggle.DataContext is not InstanceResource resource
            || !resource.CanToggle || _activeModsInstance is not { } instance) return;

        try
        {
            var run = BeginGameDirectoryWrite(instance);
            try
            {
            var source = Path.GetFullPath(resource.Path);
            var resourceRoot = Path.GetFullPath(Path.Combine(run, resource.Kind));
            EnsureOrdinaryDirectory(resourceRoot);
            var parent = Path.GetDirectoryName(source);
            if (!string.Equals(parent, resourceRoot, StringComparison.OrdinalIgnoreCase)
                || (!File.Exists(source) && !Directory.Exists(source))
                || !Directory.Exists(resourceRoot)
                || (File.GetAttributes(resourceRoot) & FileAttributes.ReparsePoint) != 0
                || (File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("资源不在此实例对应的普通目录中。");

            var enabled = toggle.IsChecked == true;
            var destination = enabled && source.EndsWith(".disabled", StringComparison.OrdinalIgnoreCase)
                ? source[..^".disabled".Length]
                : !enabled && !source.EndsWith(".disabled", StringComparison.OrdinalIgnoreCase)
                    ? source + ".disabled"
                    : throw new IOException("资源名称已变化，请刷新后重试。");
            if (File.Exists(destination) || Directory.Exists(destination))
                throw new IOException("目标名称已存在，没有覆盖任何资源。");
            if (Directory.Exists(source)) Directory.Move(source, destination);
            else File.Move(source, destination);
            }
            finally { _gameDirectoryWrites.Remove(run); }
            if (_activeModsInstance == instance) await LoadResourcesAsync();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            toggle.IsChecked = resource.Enabled;
            ShowStatus("更改资源状态失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async Task LaunchAsync(GameInstance instance, string? serverAddress = null)
    {
        if (_closing) return;
        if (!Directory.Exists(instance.RunDirectory))
        {
            ShowStatus("实例运行目录不存在。可在「更多」中重新选择目录。", InfoBarSeverity.Warning);
            return;
        }
        if (_launchTask is { IsCompleted: false })
        {
            ShowStatus("当前已有游戏启动任务。", InfoBarSeverity.Warning);
            return;
        }
        if (_gameDirectoryWrites.Contains(GameDirectoryKey(instance.RunDirectory)))
        {
            ShowStatus("此游戏目录正在写入。请等操作完成后再启动。", InfoBarSeverity.Warning);
            return;
        }

        var java = JavaRuntimeLocator.FindLauncherJava();
        if (java is null)
        {
            ShowStatus("找不到 Java 21。请先准备随应用提供的运行时，或设置 JAVA_HOME。", InfoBarSeverity.Error);
            return;
        }

        var arguments = new Dictionary<string, object?>
        {
            ["id"] = instance.Id,
            ["runDirectory"] = instance.RunDirectory,
            ["loader"] = instance.Loader,
            ["version"] = instance.Version,
            ["username"] = AppPaths.OfflineUsername,
            ["memory"] = (int)ReadSettingNumber("gameMemory", 3072, 1024, 6144),
            ["completeDependencies"] = CompleteDependencies.IsOn,
            ["serverAddress"] = serverAddress ?? ""
        };
        var gameJava = AppPaths.GetPreference(JavaPreferenceKey(instance));
        arguments["javaExplicit"] = gameJava.Length > 0;
        arguments["gameJava"] = gameJava;

        try
        {
            var accountId = AppPaths.SelectedAccountId;
            if (!string.IsNullOrWhiteSpace(accountId))
            {
                var account = AccountStore.ReadAll().FirstOrDefault(item => item.Id == accountId);
                var payload = account is null || account.RequiresReauth ? null : AccountStore.LoadPayload(account.Id);
                if (payload is null)
                {
                    ShowStatus("当前账号需要重新登录。请到账号页面完成认证。", InfoBarSeverity.Warning);
                    return;
                }
                arguments["accountType"] = account!.Kind;
                arguments["account"] = payload;
            }
            var controlDirectory = Path.Combine(AppPaths.DataDirectory, "launch-control");
            Directory.CreateDirectory(controlDirectory);
            _stopFile = Path.Combine(controlDirectory, $"{Guid.NewGuid():D}.stop");
            arguments["stopFile"] = _stopFile;
            _gameProcess = null;
            _runningGameRunDirectory = instance.RunDirectory;
            ApplyTheme();
            UpdateWallpaperPlayback();
            StopGameButton.IsEnabled = false;
            ShowStatus($"正在启动 {instance.Id}…", InfoBarSeverity.Informational);
            var historyId = Guid.NewGuid();
            arguments["historySessionID"] = historyId.ToString();
            var peers = _nextPlayPeers;
            _nextPlayPeers = [];
            _launchTask = RunLaunchAsync(java, arguments, instance, historyId, peers);
            await _launchTask;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            ShowStatus("Windows 无法读取当前账号的凭据，请重新登录。", InfoBarSeverity.Error);
        }
        catch (Exception error)
        {
            ShowStatus("无法启动实例：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async Task RunLaunchAsync(string java, IReadOnlyDictionary<string, object?> arguments,
        GameInstance instance, Guid historyId, string[] peers)
    {
        try
        {
            await PauseLanguageForGameAsync();
            var result = await new BridgeClient(java).InvokeAsync("launch", arguments, HandleBridgeEvent);
            var exitCode = result["exitCode"]?.GetValue<int>() ?? 0;
            try
            {
                PlayHistoryStore.Complete(instance, historyId, peers);
                if (_friendsClient is { } client && _friends?.Me.Sharing == true)
                    _ = FriendsOperationAsync(() => UploadLocalPlayHistoryAsync(client));
            }
            catch (Exception error) { StartupDiagnostics.Write("保存游玩记录失败", error); }
            ShowStatus(exitCode == 0 ? "Minecraft 已退出。" : $"Minecraft 异常退出，退出码 {exitCode}。可在数据目录的 logs 中查看日志。",
                exitCode == 0 ? InfoBarSeverity.Informational : InfoBarSeverity.Warning);
        }
        catch (Exception error)
        {
            ShowStatus(error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            _gameProcess?.Dispose();
            _gameProcess = null;
            _runningGameRunDirectory = null;
            ApplyTheme();
            UpdateWallpaperPlayback();
            StopGameButton.IsEnabled = false;
            if (_stopFile is not null)
            {
                try { File.Delete(_stopFile); }
                catch (IOException) { }
            }
            _stopFile = null;
            ResumeLanguageAfterGame();
        }
    }

    private void HandleBridgeEvent(System.Text.Json.Nodes.JsonObject message)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var kind = message["event"]?.GetValue<string>();
            if (kind == "progress")
            {
                var detail = message["message"]?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(detail)) ShowStatus(detail, InfoBarSeverity.Informational);
            }
            else if (kind == "launched" && message["pid"] is { } pidValue)
            {
                try
                {
                    _gameProcess = Process.GetProcessById(checked((int)pidValue.GetValue<long>()));
                    StopGameButton.IsEnabled = true;
                    UpdateFeaturedLaunch();
                    ShowStatus("Minecraft 正在运行。", InfoBarSeverity.Success);
                }
                catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    ShowStatus("游戏已启动，但暂时无法取得其进程窗口。", InfoBarSeverity.Warning);
                }
            }
            else if (kind == "accountUpdated" && message["data"] is JsonObject accountData)
            {
                try
                {
                    var saved = AccountStore.Save((JsonObject)accountData.DeepClone());
                    RefreshAccounts();
                }
                catch (Exception error)
                {
                    ShowStatus("账号会话未能安全保存。请稍后重新登录。" + " " + error.Message, InfoBarSeverity.Error);
                }
            }
        });
    }

    private async void ImportAccounts_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var types = new ComboBox
            {
                ItemsSource = new[] { "扫描常用 HMCL 位置", "指定配置或程序目录", "选取账号 JSON 文件" },
                SelectedIndex = 0, MinWidth = 275
            };
            var prompt = FriendDialog("导入旧 HMCL 账号", types, "查找账号");
            if (await prompt.ShowAsync() != ContentDialogResult.Primary) return;
            var arguments = new Dictionary<string, object?>();
            if (types.SelectedIndex == 1)
            {
                var folder = await PickFolderAsync();
                if (folder is null) return;
                arguments["migrationRoots"] = new[] { folder.Path };
            }
            else if (types.SelectedIndex == 2)
            {
                var file = await PickFileAsync(".json");
                if (file is null) return;
                arguments["migrationFiles"] = new[] { file.Path };
            }
            ShowStatus("正在只读扫描 HMCL 账号文件…", InfoBarSeverity.Informational);
            var result = await RequireBridge().InvokeAsync("migrate", arguments);
            var imported = 0;
            var reauth = 0;
            if (result["accounts"] is JsonArray accounts)
            {
                var existing = AccountStore.ReadAll().ToDictionary(item => item.Id);
                foreach (var entry in accounts)
                {
                    if (entry is not JsonObject account) continue;
                    var requiresReauth = account["requiresReauth"]?.GetValue<bool>() == true;
                    var id = account["metadata"]?["id"]?.GetValue<string>() ?? "";
                    if (id.Length == 0 || (existing.TryGetValue(id, out var saved) && !saved.RequiresReauth)) continue;
                    var stored = AccountStore.Save(account, requiresReauth);
                    existing[stored.Id] = stored;
                    imported++;
                    if (requiresReauth) reauth++;
                }
            }
            RefreshAccounts();
            var failures = result["failures"]?.AsArray().Count ?? 0;
            ShowStatus(imported == 0 ? "没有新的 HMCL 账号可以导入。"
                : $"已导入 {imported} 个 HMCL 账号。" + (reauth > 0 ? $"{reauth} 个需要重新登录。" : "")
                    + (failures > 0 ? $"{failures} 个读取提示。" : ""),
                reauth + failures > 0 ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            ShowStatus("HMCL 账号导入失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private void UseOfflineAccount(string username)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(username, "^[A-Za-z0-9_]{3,16}$"))
        {
            ShowStatus("离线昵称需为 3–16 位英文、数字或下划线。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            AppPaths.OfflineUsername = username;
            AccountStore.Select(null);
            RefreshAccounts();
            ShowStatus($"已选用离线账号 {username}。", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus("离线账号保存失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void MicrosoftLogin_Click(object sender, RoutedEventArgs e)
    {
        var java = JavaRuntimeLocator.FindLauncherJava();
        if (java is null)
        {
            ShowStatus("Microsoft 登录需要 Java 21 运行时。", InfoBarSeverity.Error);
            return;
        }
        ShowStatus("正在请求 Microsoft 设备验证码…", InfoBarSeverity.Informational);
        try
        {
            var result = await new BridgeClient(java).InvokeAsync("login", onEvent: message =>
            {
                if (message["event"]?.GetValue<string>() == "device")
                    DispatcherQueue.TryEnqueue(() => PresentDeviceCode(message));
            });
            var account = AccountStore.Save(result);
            AccountStore.Select(account.Id);
            RefreshAccounts();
            ShowStatus("Microsoft 账号已保存并选中。", InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            ShowStatus("Microsoft 登录未完成：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void PresentDeviceCode(JsonObject message)
    {
        var code = message["deviceCode"]?.GetValue<string>() ?? "";
        var url = message["url"]?.GetValue<string>() ?? "https://microsoft.com/devicelogin";
        var dialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = "Microsoft 设备登录",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock { Text = "在 Microsoft 登录页面输入以下验证码：", TextWrapping = TextWrapping.Wrap },
                    new TextBlock { Text = code, FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }
                }
            },
            PrimaryButtonText = "打开登录页面",
            CloseButtonText = "稍后",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && Uri.TryCreate(url, UriKind.Absolute, out var uri))
            await global::Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private void RefreshAccounts(bool refreshSkin = false)
    {
        try
        {
            var accounts = AccountStore.ReadAll();
            _updatingAccounts = true;
            var selectedId = AppPaths.SelectedAccountId;
            var entries = accounts.Select(account => new AccountListEntry(account, account.Id == selectedId,
                _accountAvatars.GetValueOrDefault(account.Id))).ToArray();
            AccountsList.ItemsSource = entries;
            AccountsList.Visibility = accounts.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            AccountListEmpty.Visibility = accounts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            var selected = entries.FirstOrDefault(entry => entry.Account.Id == selectedId);
            AccountsList.SelectedItem = selected;
            UpdateAccountPresentation(selected?.Account);
            if (AccountWorkspace.Visibility == Visibility.Visible)
                _ = LoadSelectedAccountSkinPreviewAsync(refreshSkin);
        }
        catch (Exception error)
        {
            ShowStatus("无法读取本地账号列表：" + error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            _updatingAccounts = false;
        }
    }

    private void Accounts_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingAccounts || AccountsList.SelectedItem is not AccountListEntry { Account: var account }) return;
        try
        {
            AccountStore.Select(account.Id);
            RefreshAccounts();
            if (account.RequiresReauth) ShowStatus("此账号需要重新登录后才能启动游戏。", InfoBarSeverity.Warning);
        }
        catch (Exception error)
        {
            ShowStatus(error.Message, InfoBarSeverity.Error);
        }
    }

    private async void StopGame_Click(object sender, RoutedEventArgs e) => await RequestStopAsync();

    private async Task<bool> RequestStopAsync()
    {
        var game = _gameProcess;
        if (game is null || game.HasExited)
        {
            ShowStatus("Minecraft 尚未进入可关闭状态。", InfoBarSeverity.Warning);
            return false;
        }

        try
        {
            game.Refresh();
            if (!game.CloseMainWindow())
            {
                ShowStatus("尚未找到游戏窗口。请回到游戏保存并正常退出。", InfoBarSeverity.Warning);
                return false;
            }

            var wait = game.WaitForExitAsync();
            if (await Task.WhenAny(wait, Task.Delay(TimeSpan.FromSeconds(30))) == wait)
            {
                ShowStatus("Minecraft 已正常退出。", InfoBarSeverity.Success);
                return true;
            }

            var dialog = new ContentDialog
            {
                XamlRoot = RootShell.XamlRoot,
                Title = "游戏仍在运行",
                Content = "请先确认游戏已保存。强制退出可能丢失尚未保存的进度。",
                PrimaryButtonText = "强制退出",
                CloseButtonText = "继续等待",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return false;

            if (_stopFile is not null) await File.WriteAllTextAsync(_stopFile, "force");
            ShowStatus("已发送强制退出请求。", InfoBarSeverity.Warning);
            return true;
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            ShowStatus(error.Message, InfoBarSeverity.Error);
            return false;
        }
    }

    private static bool IsInstancePage(string? tag) => tag is "collections" or "localization" or "instance-settings";

    private void NavigateTo(string tag)
    {
        if (_lastNavigationTag == tag) return;
        if (tag != "accounts") CancelAccountSkinPreview();
        if (_appearanceWindowLoaded)
        {
            if (tag == "settings") PlayInterfaceSound("open");
            else if (_lastNavigationTag == "settings") PlayInterfaceSound("close");
            else PlayInterfaceSound("navigate");
        }
        _lastNavigationTag = tag;
        var isGames = tag == "games";
        var showWorkspace = IsInstancePage(tag) && _activeModsInstance is not null;
        var showResources = showWorkspace && tag == "collections";
        var showLanguage = tag == "localization";
        var showMultiplayer = tag == "multiplayer";
        var showFriends = tag == "friends";
        var showSettings = tag == "settings";
        var showModFolders = tag == "modfolders";
        var showAccounts = tag == "accounts";

        PageEyebrow.Text = IsInstancePage(tag) ? "游戏" : SidebarPages.First(page => page.Page == tag).Label;
        PageTitle.FontSize = showFriends ? 32 : 34;
        PageTitle.Text = tag switch
        {
            "games" => "游戏库",
            "friends" => "好友与最近游戏",
            "collections" => "实例资源",
            "localization" => "汉化",
            "instance-settings" => "实例设置",
            _ => PageEyebrow.Text
        };
        PageSubtitle.Text = isGames ? $"{_instances.Count} 个游戏实例" : "收藏常用模组，按实例版本导入。";
        PageSubtitle.Visibility = VisibleWhen(isGames || showModFolders);
        GameActions.Visibility = InstanceList.Visibility = VisibleWhen(isGames);
        InstanceResourcesCard.Visibility = ResourcesList.Visibility = VisibleWhen(showResources);
        InstanceSettingsCard.Visibility = VisibleWhen(showWorkspace && tag == "instance-settings");
        LocalizationCard.Visibility = LocalizationWorkspace.Visibility = VisibleWhen(showLanguage);
        MultiplayerPage.Visibility = VisibleWhen(showMultiplayer);
        FriendsPage.Visibility = FriendsRefreshButton.Visibility = VisibleWhen(showFriends);
        SettingsPage.Visibility = SettingsSearch.Visibility = VisibleWhen(showSettings);
        ModFoldersPage.Visibility = NewModFolderButton.Visibility = VisibleWhen(showModFolders);
        AccountTopActions.Visibility = AccountWorkspace.Visibility = VisibleWhen(showAccounts);
        FeatureMessage.Text = "请先在游戏库中选择一个实例。";
        FeatureMessage.Visibility = VisibleWhen(IsInstancePage(tag) && !showWorkspace && !showLanguage);

        CloseStatus();
        UpdateWorkspaceHeader();
        UpdateDownloadLayout();
        UpdateNavigationSelection();
        UpdatePageSelections();
        QueueGlassCardsRefresh();
        if (showAccounts) RefreshAccounts();
        if (showLanguage)
        {
            LanguageInstance.Visibility = VisibleWhen(!showWorkspace);
            PrepareLanguageWorkspace();
        }
        if (showMultiplayer) PrepareMultiplayer();
        if (showModFolders)
        {
            CloseModFolderDetail();
            RefreshModFolders();
        }
        UpdateFriendsPage(showFriends);
        if (showResources) _ = LoadResourcesAsync();
    }

    private static bool IsSafeInstanceName(string value) => IsSafeFileName(value, 100);

    private static bool IsSafeFileName(string value, int maxLength = 240)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maxLength || value.EndsWith('.') || value.EndsWith(' ')) return false;
        if (value.Any(character => char.IsControl(character) || Path.GetInvalidFileNameChars().Contains(character))) return false;
        var device = value.Split('.')[0].TrimEnd(' ');
        return !System.Text.RegularExpressions.Regex.IsMatch(device, "^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }

    private void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        if (_closePromptOpen) return;
        _closePromptOpen = true;
        _ = CloseApplicationAsync();
    }

    private async Task CloseApplicationAsync()
    {
        try
        {
            if (_gameDirectoryWrites.Count > 0 || _instanceDownloadTask is { IsCompleted: false })
            {
                ShowStatus("正在处理实例文件。请等待写入完成后再关闭。", InfoBarSeverity.Warning);
                return;
            }
            if (_launchTask is { IsCompleted: false } launch)
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = RootShell.XamlRoot,
                    Title = "Minecraft 正在启动或运行",
                    Content = "关闭启动器前会请求 Minecraft 保存并退出。",
                    PrimaryButtonText = "关闭游戏并退出",
                    CloseButtonText = "返回启动器",
                    DefaultButton = ContentDialogButton.Close
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                _closing = true;
                if (!launch.IsCompleted && !await RequestStopAsync()) return;
                await launch;
            }
            _closing = true;
            _resumeAfterGame = false;
            _languageTranslation?.Cancel();
            _roomCancellation?.Cancel();
            _sakuraCancellation?.Cancel();
            _friendsLife?.Cancel();
            _playHistoryRequest?.Cancel();
            _catalogCancellation?.Cancel();
            await Task.WhenAll(_languageTranslationTask ?? Task.CompletedTask, _roomTask ?? Task.CompletedTask,
                _sakuraTask ?? Task.CompletedTask, _catalogTask ?? Task.CompletedTask);
            _allowClose = true;
            if (!DispatcherQueue.TryEnqueue(Close)) Application.Current.Exit();
        }
        catch (Exception error) { ShowStatus("退出时遇到问题：" + error.Message, InfoBarSeverity.Error); }
        finally
        {
            _closePromptOpen = false;
            if (!_allowClose)
            {
                _closing = false;
                if (_launchTask is null or { IsCompleted: true }) ResumeLanguageAfterGame();
            }
        }
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
        if (severity == InfoBarSeverity.Success)
            PlayInterfaceSound(message == "Minecraft 正在运行。" ? "launch" : "success");
        else if (severity == InfoBarSeverity.Error) PlayInterfaceSound("error");
    }

    private void CloseStatus() => StatusBar.IsOpen = false;
}
