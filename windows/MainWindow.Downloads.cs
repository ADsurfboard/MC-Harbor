using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private static readonly (string Id, string Name)[] Loaders =
    [
        ("vanilla", "原版"), ("fabric", "Fabric"), ("forge", "Forge"), ("neoforge", "NeoForge"),
        ("quilt", "Quilt"), ("cleanroom", "Cleanroom"), ("legacyfabric", "Legacy Fabric")
    ];

    private readonly List<RemoteGameVersion> _remoteVersions = [];
    private readonly ObservableCollection<DownloadJob> _downloadJobs = [];
    private string _downloadCategory = "minecraft";
    private string _versionFilter = "release";
    private bool _loadingRemoteVersions;
    private bool _installDialogOpen;
    private Task? _instanceDownloadTask;

    private void DownloadTab_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string category } && category != _downloadCategory)
            OpenDownloads(category);
    }

    private void OpenDownloads(string category, GameInstance? target = null)
    {
        var wantsCatalog = category is not ("minecraft" or "tasks");
        if (wantsCatalog && category != _downloadCategory) ResetCatalogResults(category);
        _downloadCategory = category;
        if (_lastNavigationTag != "downloads") NavigateTo("downloads");
        else
        {
            CloseStatus();
            UpdateDownloadLayout();
        }
        if (!wantsCatalog) return;
        if (target is not null)
            CatalogInstance.SelectedItem = _instances.FirstOrDefault(item => item.Directory == target.Directory);
        if (CatalogResults.ItemsSource is null) _ = SearchCurrentCatalogAsync();
    }

    private void UpdateDownloadLayout()
    {
        var visible = _lastNavigationTag == "downloads";
        var catalog = visible && _downloadCategory is not ("minecraft" or "tasks");
        DownloadTabs.Visibility = VisibleWhen(visible);
        DownloadActions.Visibility = VersionsRefreshButton.Visibility = VisibleWhen(visible && _downloadCategory == "minecraft");
        CatalogPage.Visibility = VisibleWhen(catalog);
        CatalogTargetPicker.Visibility = VisibleWhen(catalog && _downloadCategory != "modpack");
        DownloadTasksPage.Visibility = VisibleWhen(visible && _downloadCategory == "tasks");
        PageHeader.Visibility = VisibleWhen(!catalog);
        if (!visible) return;
        PageTitle.Text = _downloadCategory == "tasks" ? "任务" : "下载";
        if (catalog) PrepareCatalog();
        if (_downloadCategory == "minecraft")
        {
            UpdateVersionRows();
            if (_remoteVersions.Count == 0) _ = LoadRemoteVersionsAsync();
        }
        UpdateTabSelection(DownloadCategories, _downloadCategory);
        QueueGlassCardsRefresh();
    }

    private void VersionFilter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string filter } || _versionFilter == filter) return;
        _versionFilter = filter;
        UpdateVersionRows();
        UpdateTabSelection(VersionFilters, filter);
    }

    private void VersionQuery_Changed(object sender, TextChangedEventArgs e)
    {
        if (VersionsEmpty is not null) UpdateVersionRows();
    }

    private void UpdateVersionRows()
    {
        var query = VersionQuery.Text.Trim();
        var rows = _remoteVersions.Where(version => (_versionFilter == "all" || version.Type == _versionFilter)
            && (version.Id.Contains(query, StringComparison.OrdinalIgnoreCase)
                || version.Version.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        RemoteVersionsList.ItemsSource = rows;
        VersionsEmpty.Text = _loadingRemoteVersions ? "正在读取版本…" : _remoteVersions.Count == 0 ? "暂无版本" : "没有匹配的版本";
        VersionsEmpty.Visibility = VisibleWhen(rows.Length == 0);
    }

    private async void RefreshVersions_Click(object sender, RoutedEventArgs e) => await LoadRemoteVersionsAsync();

    private async Task LoadRemoteVersionsAsync()
    {
        if (_loadingRemoteVersions) return;
        _loadingRemoteVersions = true;
        UpdateVersionRows();
        VersionsRefreshButton.IsEnabled = false;
        try
        {
            var result = await RequireBridge().InvokeAsync("gameVersions");
            var versions = new List<RemoteGameVersion>();
            if (result["versions"] is JsonArray rows)
            {
                foreach (var row in rows.OfType<JsonObject>())
                {
                    var id = row["id"]?.GetValue<string>() ?? "";
                    if (id.Length == 0) continue;
                    versions.Add(new RemoteGameVersion(id, row["version"]?.GetValue<string>() ?? id,
                        row["type"]?.GetValue<string>() ?? "unknown", row["releaseTime"]?.GetValue<string>() ?? ""));
                }
            }
            _remoteVersions.Clear();
            _remoteVersions.AddRange(versions);
            if (DownloadActions.Visibility == Visibility.Visible)
            {
                if (versions.Count == 0) ShowStatus("版本列表为空。请检查网络或切换下载源后重试。", InfoBarSeverity.Warning);
                else CloseStatus();
            }
        }
        catch (Exception error)
        {
            if (DownloadActions.Visibility == Visibility.Visible)
                ShowStatus("读取 Minecraft 版本失败：" + error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            _loadingRemoteVersions = false;
            VersionsRefreshButton.IsEnabled = true;
            UpdateVersionRows();
        }
    }

    private async void InstallVersion_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: RemoteGameVersion game } || _installDialogOpen || _closing) return;
        if (_instanceDownloadTask is { IsCompleted: false })
        {
            ShowStatus("请等待当前实例安装完成。", InfoBarSeverity.Informational);
            return;
        }
        _installDialogOpen = true;
        try { await PromptInstallVersionAsync(game); }
        catch (Exception error) { ShowStatus("无法安装实例：" + error.Message, InfoBarSeverity.Error); }
        finally { _installDialogOpen = false; }
    }

    private async Task PromptInstallVersionAsync(RemoteGameVersion game)
    {
        var bridge = RequireBridge();
        var name = new TextBox { Header = "实例名称", Text = game.Version, MaxLength = 100, MinWidth = 260 };
        var loader = new ComboBox { Header = "加载器", HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var option in Loaders) loader.Items.Add(new ComboBoxItem { Content = option.Name, Tag = option.Id });
        loader.SelectedIndex = 0;
        var versions = new ComboBox
        {
            Header = "加载器版本", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var detail = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var form = new StackPanel { Spacing = 12, Children = { name, loader, versions, detail } };
        var dialog = FriendDialog($"安装 {game.Version}", form, "安装");
        dialog.CloseButtonText = "取消";
        using var lifetime = new CancellationTokenSource();
        CancellationTokenSource? loaderRequest = null;
        var installedLoader = "vanilla";

        loader.SelectionChanged += async (_, _) =>
        {
            loaderRequest?.Cancel();
            if (loader.SelectedItem is not ComboBoxItem { Tag: string selected }) return;
            installedLoader = selected;
            versions.ItemsSource = null;
            var hasLoader = installedLoader != "vanilla";
            versions.Visibility = VisibleWhen(hasLoader);
            dialog.IsPrimaryButtonEnabled = !hasLoader;
            detail.Text = "";
            if (!hasLoader) return;

            using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            loaderRequest = request;
            detail.Text = "正在读取加载器版本…";
            try
            {
                var result = await bridge.InvokeAsync("loaders", new Dictionary<string, object?>
                {
                    ["version"] = game.Version, ["loader"] = installedLoader
                }, cancellationToken: request.Token);
                if (request.IsCancellationRequested) return;
                var rows = (result["versions"] as JsonArray ?? []).Select(item => item?.GetValue<string>())
                    .OfType<string>().Where(item => item.Length > 0).ToArray();
                versions.ItemsSource = rows;
                versions.SelectedIndex = rows.Length > 0 ? 0 : -1;
                dialog.IsPrimaryButtonEnabled = rows.Length > 0;
                detail.Text = rows.Length > 0 ? "" : "没有适用于此 Minecraft 版本的加载器版本。";
            }
            catch (OperationCanceledException) when (request.IsCancellationRequested) { }
            catch (Exception error)
            {
                if (!request.IsCancellationRequested) detail.Text = "读取加载器版本失败：" + error.Message;
            }
            finally
            {
                if (loaderRequest == request) loaderRequest = null;
            }
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (IsSafeInstanceName(name.Text.Trim())) return;
            args.Cancel = true;
            detail.Text = "请填写有效的实例名称。";
        };
        ContentDialogResult disposition;
        try { disposition = await dialog.ShowAsync(); }
        finally { lifetime.Cancel(); }
        if (disposition != ContentDialogResult.Primary) return;

        var instanceName = name.Text.Trim();
        await StartInstanceDownloadAsync(bridge, "install", new Dictionary<string, object?>
        {
            ["version"] = game.Version,
            ["name"] = instanceName,
            ["loader"] = installedLoader,
            ["loaderVersion"] = versions.SelectedItem as string ?? ""
        }, $"安装 {instanceName}", _ => $"实例 {instanceName} 已安装。");
    }

    private Task StartInstanceDownloadAsync(BridgeClient bridge, string operation, Dictionary<string, object?> arguments,
        string title, Func<JsonObject, string> success)
    {
        if (_closing || _instanceDownloadTask is { IsCompleted: false })
        {
            ShowStatus("请等待当前实例安装完成。", InfoBarSeverity.Informational);
            return Task.CompletedTask;
        }
        arguments["root"] = AppPaths.GameRoot;
        _instanceDownloadTask = RunInstanceDownloadAsync(bridge, operation, arguments, title, success);
        return _instanceDownloadTask;
    }

    private async Task RunInstanceDownloadAsync(BridgeClient bridge, string operation, Dictionary<string, object?> arguments,
        string title, Func<JsonObject, string> success)
    {
        var job = AddDownloadJob(title);
        ShowStatus($"{title}…", InfoBarSeverity.Informational);
        try
        {
            var result = await bridge.InvokeAsync(operation, arguments, message =>
            {
                if (message["event"]?.GetValue<string>() == "progress"
                    && message["message"]?.GetValue<string>() is { Length: > 0 } detail)
                    DispatcherQueue.TryEnqueue(() => { if (job.Running) job.Report(detail); });
            });
            var complete = success(result);
            job.Finish(complete);
            await RefreshInstancesAsync();
            if (CatalogPage.Visibility == Visibility.Visible) PrepareCatalog();
            ShowStatus(complete, InfoBarSeverity.Success);
        }
        catch (Exception error)
        {
            var failed = title + "失败：" + error.Message;
            job.Finish(failed);
            ShowStatus(failed, InfoBarSeverity.Error);
        }
    }

    private DownloadJob AddDownloadJob(string title, Action? cancel = null)
    {
        var job = new DownloadJob(title, cancel);
        _downloadJobs.Insert(0, job);
        if (_downloadJobs.Count > 40 && _downloadJobs.LastOrDefault(item => !item.Running) is { } oldest)
            _downloadJobs.Remove(oldest);
        DownloadTasksEmpty.Visibility = Visibility.Collapsed;
        return job;
    }

    private void CancelDownloadJob_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { DataContext: DownloadJob job }) job.Cancel();
    }

    private async Task RunResourceDownloadAsync(string title, TextBlock status, CancellationToken cancellation,
        Func<DownloadJob, Task> apply)
    {
        var source = _catalogCancellation;
        var job = AddDownloadJob(title, source is null ? null : source.Cancel);
        try
        {
            await apply(job);
            job.Finish(status.Text);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            job.Finish("任务已取消。");
            throw;
        }
        catch (Exception error)
        {
            job.Finish(error.Message);
            throw;
        }
    }

}

public sealed class DownloadJob(string title, Action? cancel) : INotifyPropertyChanged
{
    private Action? _cancel = cancel;
    public string Title { get; } = title;
    public string Detail { get; private set; } = "准备中…";
    public bool Running { get; private set; } = true;
    public Visibility BusyVisibility => Running ? Visibility.Visible : Visibility.Collapsed;
    public Visibility CancelVisibility => Running && _cancel is not null ? Visibility.Visible : Visibility.Collapsed;
    public event PropertyChangedEventHandler? PropertyChanged;

    internal void Report(string detail)
    {
        Detail = detail;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Detail)));
    }

    internal void Cancel()
    {
        var cancelJob = _cancel;
        StopOfferingCancel();
        cancelJob?.Invoke();
    }

    internal void StopOfferingCancel()
    {
        _cancel = null;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CancelVisibility)));
    }

    internal void Finish(string detail)
    {
        Running = false;
        StopOfferingCancel();
        Report(detail);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(BusyVisibility)));
    }
}
