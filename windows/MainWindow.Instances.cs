using System.Runtime.InteropServices;
using System.Text.Json;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private bool _libraryLoaded;
    private readonly Queue<string> _activationInstances = new();

    internal void QueueActivation(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return;
        if (_libraryLoaded) _ = LaunchFromShortcutAsync(id);
        else _activationInstances.Enqueue(id);
    }

    private async Task LaunchFromShortcutAsync(string id)
    {
        if (_closing) return;
        if (_instances.FirstOrDefault(instance => instance.Id.Equals(id, StringComparison.OrdinalIgnoreCase)) is not { } target)
        {
            ShowStatus($"当前游戏目录中没有找到 {id}。请选择原游戏目录后重试。", InfoBarSeverity.Warning);
            return;
        }
        NavigateTo("games");
        await LaunchAsync(target);
    }

    private void GameFilter_Changed(object sender, TextChangedEventArgs e)
    {
        if (_libraryLoaded) ApplyGameFilter();
    }

    private void ApplyGameFilter()
    {
        var filter = GameFilter.Text.Trim();
        var favorites = ReadFavoriteInstances();
        var previous = (InstanceList.SelectedItem as GameInstance)?.Directory;
        var instances = _instances.Where(item => filter.Length == 0
            || item.Id.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || item.Version.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || item.Loader.Contains(filter, StringComparison.OrdinalIgnoreCase))
            .Select(item => item with { Favorite = favorites.Contains(item.Directory) })
            .OrderByDescending(item => item.Favorite).ToArray();
        InstanceList.ItemsSource = instances;
        InstanceList.SelectedItem = instances.FirstOrDefault(item => item.Directory == previous) ?? instances.FirstOrDefault();
        LibraryGameCount.Text = _instances.Count.ToString(System.Globalization.CultureInfo.CurrentCulture);
        LibraryGameCount.Visibility = _instances.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (_lastNavigationTag == "games") PageSubtitle.Text = $"{_instances.Count} 个游戏实例";
        UpdateFeaturedGame();
    }

    private void GoToDownloads_Click(object sender, RoutedEventArgs e) => OpenDownloads("minecraft");

    private void Library_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateFeaturedGame();

    private void UpdateFeaturedGame()
    {
        if (FeaturedGameCard is null) return;
        var selected = InstanceList.SelectedItem as GameInstance;
        FeaturedGameCard.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
        if (selected is null) return;
        FeaturedGameLoader.Text = selected.Loader == "vanilla" ? "Minecraft" : selected.Loader;
        FeaturedGameName.Text = selected.Id;
        FeaturedGameVersion.Text = selected.Version;
        FeaturedGameIcon.Source = new BitmapImage(new Uri(selected.Artwork));
        FeaturedGameLaunch.Tag = FeaturedGameManage.Tag = selected.Id;
        UpdateFeaturedGameWidth();
        UpdateFeaturedLaunch();
    }

    private void UpdateFeaturedGameWidth()
    {
        if (FeaturedGameLayout is null) return;
        var showArt = RootShell.ActualWidth >= 940 && !_chromeHighContrast;
        FeaturedGameLayout.ColumnDefinitions[1].Width = new GridLength(showArt ? 252 : 0);
        FeaturedGameArt.Visibility = showArt ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateFeaturedLaunch()
    {
        if (FeaturedGameLaunch is null) return;
        var idle = _runningGameRunDirectory is null;
        var featured = InstanceList.SelectedItem as GameInstance;
        FeaturedGameLaunch.IsEnabled = WorkspaceLaunchButton.IsEnabled = idle;
        FeaturedGameLaunch.Content = WorkspaceLaunchButton.Content = idle ? "启动游戏" : "游戏运行中";
        FeaturedGameStop.Visibility = VisibleWhen(StopGameButton.IsEnabled && IsRunningInstance(featured));
        WorkspaceStopButton.Visibility = VisibleWhen(StopGameButton.IsEnabled && IsRunningInstance(_activeModsInstance));
    }

    private bool IsRunningInstance(GameInstance? instance) => instance is not null
        && string.Equals(instance.RunDirectory, _runningGameRunDirectory, StringComparison.OrdinalIgnoreCase);

    private static HashSet<string> ReadFavoriteInstances()
    {
        try
        {
            var favorites = JsonSerializer.Deserialize<string[]>(AppPaths.GetPreference("favoriteInstances", "[]")) ?? [];
            return new HashSet<string>(favorites, StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException) { return new HashSet<string>(StringComparer.OrdinalIgnoreCase); }
    }

    private GameInstance? MenuInstance(object sender)
    {
        if (sender is not FrameworkElement element) return null;
        if (element.DataContext is GameInstance instance) return _instances.FirstOrDefault(item => item.Directory == instance.Directory);
        return _instances.FirstOrDefault(item => item.Id == element.Tag?.ToString());
    }

    private void FavoriteGame_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        var favorites = ReadFavoriteInstances();
        var added = favorites.Add(instance.Directory);
        if (!added) favorites.Remove(instance.Directory);
        SaveSetting("favoriteInstances", JsonSerializer.Serialize(favorites));
        ApplyGameFilter();
        ShowStatus(added ? "实例已收藏。" : "已取消收藏。", InfoBarSeverity.Success);
    }

    private async void OpenInstanceDirectory_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            var folder = await global::Windows.Storage.StorageFolder.GetFolderFromPathAsync(instance.RunDirectory);
            await global::Windows.System.Launcher.LaunchFolderAsync(folder);
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private static string RunDirectoryPreferenceKey(string instanceDirectory) => "instanceRun:" + instanceDirectory.ToUpperInvariant();
    private static string JavaPreferenceKey(GameInstance instance) => "gameJava:" + instance.Directory.ToUpperInvariant();

    private async void ChooseGameJava_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            var selected = AppPaths.GetPreference(JavaPreferenceKey(instance), "自动选择");
            var choice = await FriendDialog("选择游戏 Java", new TextBlock
            {
                Text = selected, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true
            }, "选择 java.exe", "使用自动检测").ShowAsync();
            if (choice == ContentDialogResult.None) return;
            if (choice == ContentDialogResult.Secondary)
            {
                AppPaths.SetPreference(JavaPreferenceKey(instance), "");
                ShowStatus("已恢复自动选择游戏 Java。", InfoBarSeverity.Success);
                return;
            }
            var file = await PickFileAsync(".exe");
            if (file is null) return;
            if (!file.Name.Equals("java.exe", StringComparison.OrdinalIgnoreCase))
                throw new IOException("请选择 Java 安装目录中 bin 下的 java.exe。");
            var inspection = await RequireBridge().InvokeAsync("inspectJava", new Dictionary<string, object?>
            {
                ["gameJava"] = file.Path
            });
            if (inspection["compatibleArchitecture"]?.GetValue<bool>() != true)
                throw new IOException("所选 Java 架构与此 Windows 客户端不匹配。");
            AppPaths.SetPreference(JavaPreferenceKey(instance), file.Path);
            ShowStatus($"已为 {instance.Id} 选用 Java {inspection["version"]}。", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus("无法更改游戏 Java：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void RelocateInstance_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            if (_launchTask is { IsCompleted: false } || _gameDirectoryWrites.Count > 0)
                throw new IOException("请在游戏及文件操作结束后更改目录。");
            var content = new TextBlock
            {
                Text = $"当前运行目录：\n{instance.RunDirectory}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true
            };
            var result = await FriendDialog("重新定位运行目录", content, "选择目录", "还原 HMCL 设置").ShowAsync();
            if (result == ContentDialogResult.None) return;
            var path = "";
            if (result == ContentDialogResult.Primary)
            {
                var selected = await PickFolderAsync();
                if (selected is null) return;
                path = GameDirectoryKey(selected.Path);
                EnsureOrdinaryDirectory(path);
            }
            AppPaths.SetPreference(RunDirectoryPreferenceKey(instance.Directory), path);
            await RefreshInstancesAsync();
            ShowStatus(path.Length == 0 ? "已恢复读取 HMCL 设置。" : $"已更新运行目录。{path}", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private async void ChangeInstanceIcon_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            var file = await PickFileAsync(".png");
            if (file is null) return;
            EnsureOrdinaryDirectory(instance.Directory);
            var input = new FileInfo(file.Path);
            if (input.Length > 8_000_000) throw new IOException("实例图标需要小于 8 MB。");
            var bytes = await File.ReadAllBytesAsync(file.Path);
            if (bytes.Length < 24 || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })
                || System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4)) is 0 or > 4096
                || System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4)) is 0 or > 4096)
                throw new IOException("请选择宽高不超过 4096 像素的 PNG。");
            AccountStore.WriteAtomically(Path.Combine(instance.Directory, "icon.png"), bytes);
            await RefreshInstancesAsync();
        }
        catch (Exception error) { ShowStatus("无法更换图标：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void CreateShortcut_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            var folder = await PickFolderAsync();
            if (folder is null) return;
            var destination = Path.Combine(folder.Path, $"MC Harbor - {instance.Id}.lnk");
            if (File.Exists(destination)) throw new IOException("该目录已有同名快捷方式。");
            var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Windows 快捷方式服务不可用。");
            object shell = Activator.CreateInstance(shellType)!;
            object? shortcut = null;
            try
            {
                shortcut = ((dynamic)shell).CreateShortcut(destination);
                var target = Environment.ProcessPath ?? Path.Combine(AppPaths.ApplicationDirectory, "MC Harbor.exe");
                ((dynamic)shortcut).TargetPath = target;
                ((dynamic)shortcut).Arguments = $"--launch \"{instance.Id}\"";
                ((dynamic)shortcut).WorkingDirectory = AppPaths.ApplicationDirectory;
                ((dynamic)shortcut).Description = $"使用 MC Harbor 启动 {instance.Id}";
                ((dynamic)shortcut).Save();
            }
            finally
            {
                if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
                Marshal.FinalReleaseComObject(shell);
            }
            ShowStatus($"快捷方式已创建。{destination}", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus("创建快捷方式失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void RecycleInstance_Click(object sender, RoutedEventArgs e)
    {
        if (MenuInstance(sender) is not { } instance) return;
        try
        {
            if (_launchTask is { IsCompleted: false } || _catalogTask is { IsCompleted: false } || _gameDirectoryWrites.Count > 0)
                throw new IOException("请先结束游戏和资源任务。");
            var versions = GameDirectoryKey(Path.Combine(AppPaths.GameRoot, "versions"));
            var target = GameDirectoryKey(instance.Directory);
            if (!string.Equals(Path.GetDirectoryName(target), versions, StringComparison.OrdinalIgnoreCase))
                throw new IOException("无法确认实例目录的归属。");
            EnsureOrdinaryDirectory(target);
            EnsureRecycleDrive(target);
            var dependents = ReadInstanceDependents(versions, instance.Id, target);
            if (dependents.Length != 0)
                throw new IOException("以下实例继承此版本：" + string.Join("、", dependents));
            var dialog = FriendDialog("将实例移到回收站", new TextBlock
            {
                Text = $"移除 {instance.Id} 的版本目录？\n{target}", TextWrapping = TextWrapping.Wrap
            }, "移到回收站");
            dialog.DefaultButton = ContentDialogButton.Close;
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (_launchTask is { IsCompleted: false } || _catalogTask is { IsCompleted: false } || _gameDirectoryWrites.Count > 0)
                throw new IOException("请先结束游戏和资源任务。");
            var request = new SHFILEOPSTRUCT
            {
                Operation = 3, From = target + "\0\0",
                Flags = 0x0040 | 0x4000 | 0x0004
            };
            var error = RecycleFile(ref request);
            if (error != 0 || request.Aborted || Directory.Exists(target))
                throw new IOException("Windows 未能将此实例移到回收站。");
            await RefreshInstancesAsync();
            ShowStatus($"已移除实例 {instance.Id}。", InfoBarSeverity.Success);
        }
        catch (Exception error) { ShowStatus("移除实例失败：" + error.Message, InfoBarSeverity.Warning); }
    }

    private static void EnsureRecycleDrive(string target)
    {
        var root = Path.GetPathRoot(target)!;
        var drive = new DriveInfo(root);
        if (drive.DriveType != DriveType.Fixed || !Directory.Exists(Path.Combine(root, "$RECYCLE.BIN")))
            throw new IOException("此磁盘的回收站不可用，请在资源管理器中处理。");
    }

    private static string[] ReadInstanceDependents(string root, string id, string target)
    {
        var dependents = new List<string>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            if (directory.Equals(target, StringComparison.OrdinalIgnoreCase)) continue;
            var name = Path.GetFileName(directory);
            var configuration = Path.Combine(directory, name + ".json");
            if (!File.Exists(configuration)) continue;
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("有其他实例通过目录联接点存在，无法确认版本依赖。");
            using var json = JsonDocument.Parse(File.ReadAllBytes(configuration));
            if (json.RootElement.TryGetProperty("inheritsFrom", out var parent) && parent.ValueKind == JsonValueKind.String
                && id.Equals(parent.GetString(), StringComparison.OrdinalIgnoreCase))
                dependents.Add(name);
        }
        return dependents.ToArray();
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public IntPtr Window;
        public uint Operation;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        public IntPtr To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool Aborted;
        public IntPtr Mapping;
        public IntPtr ProgressTitle;
    }

    [DllImport("shell32.dll", EntryPoint = "SHFileOperationW", CharSet = CharSet.Unicode)]
    private static extern int RecycleFile(ref SHFILEOPSTRUCT operation);
}
