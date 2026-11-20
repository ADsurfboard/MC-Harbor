using System.IO.Compression;
using System.Text.Json;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private CancellationTokenSource? _catalogCancellation;
    private Task? _catalogTask;
    private int _catalogPage;
    private CatalogFilters? _catalogFilter;
    private static string CatalogEntriesFile => Path.Combine(AppPaths.DataDirectory, "collections", "market.json");

    private void PrepareCatalog()
    {
        var previous = (CatalogInstance.SelectedItem as GameInstance)?.Id;
        CatalogInstance.ItemsSource = _instances.ToArray();
        CatalogInstance.SelectedItem = _instances.FirstOrDefault(row => row.Id == previous)
            ?? InstanceList.SelectedItem as GameInstance ?? _instances.FirstOrDefault();
    }

    private void CatalogColumns_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width <= 0) return;
        var columns = (Grid)sender;
        columns.ColumnDefinitions[0].Width = new GridLength(Math.Clamp(e.NewSize.Width * 0.39, 145, 400));
        CatalogCollectActions.Orientation = e.NewSize.Width < 490 ? Orientation.Vertical : Orientation.Horizontal;
    }

    private void ResetCatalogResults(string category)
    {
        _catalogFilter = null;
        _catalogPage = 0;
        CatalogResults.ItemsSource = null;
        CatalogPrevious.IsEnabled = CatalogNext.IsEnabled = false;
        CatalogProgress.Text = "";
        if (category == "world") CatalogPlatform.SelectedIndex = 1;
    }

    private async void CatalogSearch_Click(object sender, RoutedEventArgs e) => await SearchCurrentCatalogAsync();

    private async void CatalogQuery_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != global::Windows.System.VirtualKey.Enter) return;
        e.Handled = true;
        await SearchCurrentCatalogAsync();
    }

    private Task SearchCurrentCatalogAsync()
    {
        var instance = _downloadCategory == "modpack" ? null : CatalogInstance.SelectedItem as GameInstance;
        var filters = new CatalogFilters(CatalogPlatform.SelectedIndex == 1 ? "curseforge" : "modrinth",
            _downloadCategory, CatalogQuery.Text.Trim(), instance, CatalogSort.SelectedIndex == 1);
        return SearchCatalogAsync(filters, 0);
    }

    private void CatalogResults_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CatalogDetail is null) return;
        var project = CatalogResults.SelectedItem as CatalogProject;
        CatalogDetail.DataContext = project;
        CatalogDetail.Visibility = CatalogDetailActions.Visibility = VisibleWhen(project is not null);
        CatalogDetailEmpty.Visibility = VisibleWhen(project is null);
        CatalogCollectMod.Visibility = VisibleWhen(project?.Kind == "mod");
    }

    private async void CatalogPrevious_Click(object sender, RoutedEventArgs e)
    {
        if (_catalogFilter is { } filters && _catalogPage > 0) await SearchCatalogAsync(filters, _catalogPage - 1);
    }

    private async void CatalogNext_Click(object sender, RoutedEventArgs e)
    {
        if (_catalogFilter is { } filters) await SearchCatalogAsync(filters, _catalogPage + 1);
    }

    private Task SearchCatalogAsync(CatalogFilters filters, int page) => CatalogOperationAsync(async cancellation =>
    {
        CatalogProgress.Text = "正在搜索…";
        var result = await new ResourceCatalog(RequireBridge()).SearchAsync(filters.Source, filters.Kind,
            filters.Query, filters.Instance, page, filters.Updated, cancellation);
        if (filters.Kind != _downloadCategory) return;
        _catalogFilter = filters;
        _catalogPage = page;
        CatalogResults.ItemsSource = result.Rows;
        CatalogPrevious.IsEnabled = page > 0;
        CatalogNext.IsEnabled = (page + 1) * 30 < result.Total;
        CatalogProgress.Text = result.Rows.Length == 0 ? "没有匹配结果" : $"第 {page + 1} 页 · {result.Total} 个结果";
    });

    private async void CatalogFavorites_Click(object sender, RoutedEventArgs e)
    {
        await CatalogOperationAsync(cancellation =>
        {
            var query = CatalogQuery.Text.Trim();
            var entries = ReadCatalogEntries().Where(item => item.Favorite && item.Project.Kind == _downloadCategory
                && (query.Length == 0 || item.Note.Contains(query, StringComparison.OrdinalIgnoreCase)
                    || item.Project.Name.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
            CatalogResults.ItemsSource = entries.Select(item => item.Project).ToArray();
            CatalogPrevious.IsEnabled = CatalogNext.IsEnabled = false;
            _catalogFilter = null;
            CatalogProgress.Text = $"已收藏 {entries.Length} 个项目";
            return Task.CompletedTask;
        });
    }

    private async void CatalogSave_Click(object sender, RoutedEventArgs e)
    {
        if (CatalogResults.SelectedItem is not CatalogProject item) return;
        await CatalogOperationAsync(async cancellation =>
        {
            var entries = ReadCatalogEntries();
            var existing = entries.FirstOrDefault(row => row.Project.Id == item.Id && row.Project.Source == item.Source);
            var note = new TextBox { Header = "个人备注", Text = existing?.Note ?? "", MaxLength = 120 };
            var added = new CheckBox { Content = "收藏这个项目", IsChecked = existing?.Favorite ?? true };
            var open = new HyperlinkButton { Content = "打开原项目页" };
            if (Uri.TryCreate(item.PageUrl, UriKind.Absolute, out var uri) && uri.Scheme == "https"
                && uri.Host is "modrinth.com" or "www.curseforge.com" or "curseforge.com")
                open.NavigateUri = uri;
            else open.Visibility = Visibility.Collapsed;
            var dialog = FriendDialog(item.Name, new StackPanel { Spacing = 8, Children = { note, added, open } }, "保存");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var updated = entries.Where(row => row.Project.Id != item.Id || row.Project.Source != item.Source).ToList();
            if (added.IsChecked == true || note.Text.Trim().Length != 0)
                updated.Add(new CatalogEntry(item, note.Text.Trim(), added.IsChecked == true));
            AccountStore.WriteAtomically(CatalogEntriesFile, JsonSerializer.SerializeToUtf8Bytes(updated));
            CatalogProgress.Text = "已保存";
        });
    }

    private async void CatalogInstall_Click(object sender, RoutedEventArgs e)
    {
        if (CatalogResults.SelectedItem is not CatalogProject project) return;
        var instance = project.Kind == "modpack" ? null : CatalogInstance.SelectedItem as GameInstance;
        await CatalogOperationAsync(cancellation => InstallCatalogAsync(project, instance, cancellation));
    }

    private async Task InstallCatalogAsync(CatalogProject project, GameInstance? instance, CancellationToken cancellation)
    {
        if (project.Kind != "modpack" && instance is null) throw new IOException("请选择安装目标实例。");
        if (project.Kind == "mod" && ResourceCatalog.Loader(instance) is null)
            throw new IOException("请使用已安装模组加载器的实例。");
        var root = AppPaths.GameRoot;
        var bridge = RequireBridge();
        var catalog = new ResourceCatalog(bridge);
        CatalogProgress.Text = "正在查找兼容文件…";
        var versions = await catalog.VersionsAsync(project, instance, cancellation);
        if (versions.Length == 0) throw new IOException("此实例没有兼容文件。");
        var picker = new ComboBox
        {
            Header = "兼容文件", MinWidth = 260, ItemsSource = versions,
            DisplayMemberPath = nameof(CatalogVersion.Name), SelectedIndex = 0
        };
        var layout = new StackPanel { Spacing = 8, Children = { picker } };
        TextBox? instanceName = null;
        if (project.Kind == "modpack")
        {
            instanceName = new TextBox { Header = "新实例名称", MaxLength = 100 };
            if (IsSafeInstanceName(project.Name)) instanceName.Text = project.Name;
            layout.Children.Add(instanceName);
        }
        var confirmation = FriendDialog(project.Name, layout, "下载并安装");
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary || picker.SelectedItem is not CatalogVersion version) return;
        var name = instanceName?.Text.Trim() ?? "";
        if (instanceName is not null && !IsSafeInstanceName(name)) throw new IOException("请输入有效的新实例名称。");
        cancellation.ThrowIfCancellationRequested();
        await RunResourceDownloadAsync($"下载 {project.Name}", CatalogProgress, cancellation,
            job => ApplyCatalogDownloadAsync(project, instance, version, root, name, bridge, catalog, job, cancellation));
    }

    private async Task ApplyCatalogDownloadAsync(CatalogProject project, GameInstance? instance, CatalogVersion version,
        string root, string name, BridgeClient bridge, ResourceCatalog catalog, DownloadJob job, CancellationToken cancellation)
    {
        var files = await catalog.PlanAsync(project, version, instance, cancellation);
        var extension = project.Kind == "mod" ? ".jar" : ".zip";
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (files.Length == 0 || files.Any(file => !IsSafeFileName(file.Name) || !names.Add(file.Name)
            || (!file.Name.EndsWith(extension, StringComparison.OrdinalIgnoreCase)
                && !(project.Kind == "modpack" && file.Name.EndsWith(".mrpack", StringComparison.OrdinalIgnoreCase)))))
            throw new IOException("平台文件名、扩展名或依赖列表无效。");
        var folder = Path.Combine(AppPaths.DataDirectory, "download-staging", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            for (var index = 0; index < files.Length; index++)
            {
                var file = files[index];
                CatalogProgress.Text = $"下载 {index + 1}/{files.Length} · {file.Name}";
                job.Report(CatalogProgress.Text);
                await catalog.DownloadAsync(file, Path.Combine(folder, file.Name), cancellation);
            }
            if (instance is null)
            {
                cancellation.ThrowIfCancellationRequested();
                BeginResourceDownloadCommit(job);
                await bridge.InvokeAsync("import", new Dictionary<string, object?>
                {
                    ["root"] = root, ["file"] = Path.Combine(folder, files[0].Name), ["name"] = name
                }, HandleBridgeEvent);
                if (AppPaths.GameRoot == root) await RefreshInstancesAsync();
                CatalogProgress.Text = $"整合包已安装为 {name}。";
                return;
            }
            await WaitForGameDirectoryAsync(instance, CatalogProgress, job, cancellation);
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                cancellation.ThrowIfCancellationRequested();
                BeginResourceDownloadCommit(job);
                if (project.Kind == "world")
                {
                    EnsureOrdinaryDirectory(Path.Combine(run, "saves"));
                    await bridge.InvokeAsync("installWorld", new Dictionary<string, object?>
                    {
                        ["root"] = root, ["runDirectory"] = run, ["name"] = project.Name,
                        ["file"] = Path.Combine(folder, files[0].Name)
                    });
                }
                else
                    await CommitCatalogFilesAsync(run, project.Kind, folder, files, project.PageUrl);
                CatalogProgress.Text = $"已安装到 {instance.Id}。";
                if (_activeModsInstance == instance && ResourcesList.Visibility == Visibility.Visible) await LoadResourcesAsync();
            }
            finally { _gameDirectoryWrites.Remove(run); }
        }
        finally
        {
            foreach (var file in files) File.Delete(Path.Combine(folder, file.Name));
            Directory.Delete(folder);
        }
    }

    private async Task WaitForGameDirectoryAsync(GameInstance instance, TextBlock status, DownloadJob job, CancellationToken cancellation)
    {
        while (_launchTask is { IsCompleted: false } game && _runningGameRunDirectory is { } current
            && GameDirectoryKey(current).Equals(GameDirectoryKey(instance.RunDirectory), StringComparison.OrdinalIgnoreCase))
        {
            status.Text = "文件已准备好。等待此实例退出后安装…";
            job.Report(status.Text);
            await game.WaitAsync(cancellation);
        }
        cancellation.ThrowIfCancellationRequested();
    }

    private static async Task CommitCatalogFilesAsync(string run, string kind, string downloaded, CatalogFile[] files, string source)
    {
        var category = kind switch
        {
            "mod" => "mods", "resourcepack" => "resourcepacks", "shader" => "shaderpacks",
            _ => throw new IOException("不支持的安装类型。")
        };
        var target = Path.Combine(run, category);
        EnsureOrdinaryDirectory(target);
        Directory.CreateDirectory(target);
        var staged = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var committed = new List<string>();
        try
        {
            foreach (var item in files)
            {
                var file = Path.Combine(downloaded, item.Name);
                using (var archive = ZipFile.OpenRead(file))
                    if (archive.Entries.Count == 0) throw new IOException($"归档为空：{item.Name}");
                var final = Path.Combine(target, item.Name);
                var disabled = final + ".disabled";
                if (File.Exists(final) || File.Exists(disabled))
                {
                    var existing = File.Exists(final) ? final : disabled;
                    if ((File.GetAttributes(existing) & FileAttributes.ReparsePoint) != 0
                        || !await SameFileBytesAsync(existing, file))
                        throw new IOException($"存在不同内容的同名文件：{item.Name}");
                    continue;
                }
                var stage = Path.Combine(target, $".harbor-{Guid.NewGuid():N}.partial");
                staged.Add(final, stage);
                await using var input = File.OpenRead(file);
                await using var output = new FileStream(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
                await input.CopyToAsync(output);
            }
            foreach (var (destination, stage) in staged)
            {
                File.Move(stage, destination);
                committed.Add(destination);
            }
            if (Uri.TryCreate(source, UriKind.Absolute, out var url) && url.Scheme == "https")
            {
                var receipt = Path.Combine(run, ".harbor", "resource-sources.json");
                EnsureOrdinaryDirectory(Path.GetDirectoryName(receipt)!);
                var index = File.Exists(receipt)
                    ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllBytes(receipt)) as System.Text.Json.Nodes.JsonObject
                    : null;
                index ??= new System.Text.Json.Nodes.JsonObject();
                if (files.Length == 1)
                    index[files[0].Name] = new System.Text.Json.Nodes.JsonObject { ["source"] = url.AbsoluteUri };
                AccountStore.WriteAtomically(receipt, JsonSerializer.SerializeToUtf8Bytes(index));
            }
        }
        catch
        {
            foreach (var file in committed) File.Delete(file);
            throw;
        }
        finally
        {
            foreach (var stage in staged.Values) File.Delete(stage);
        }
    }

    private static async Task<bool> SameFileBytesAsync(string path, string downloaded)
    {
        await using var original = File.OpenRead(path);
        await using var addition = File.OpenRead(downloaded);
        if (original.Length != addition.Length) return false;
        var existing = await System.Security.Cryptography.SHA256.HashDataAsync(original);
        var expected = await System.Security.Cryptography.SHA256.HashDataAsync(addition);
        return existing.AsSpan().SequenceEqual(expected);
    }

    private static CatalogEntry[] ReadCatalogEntries()
    {
        if (!File.Exists(CatalogEntriesFile)) return [];
        return JsonSerializer.Deserialize<CatalogEntry[]>(File.ReadAllBytes(CatalogEntriesFile)) ?? [];
    }

    private Task CatalogOperationAsync(Func<CancellationToken, Task> operation)
    {
        if (_closing) return Task.CompletedTask;
        if (_catalogTask is { IsCompleted: false })
        {
            ShowStatus("请等待当前的资源任务完成。", InfoBarSeverity.Informational);
            return Task.CompletedTask;
        }
        _catalogTask = RunCatalogOperationAsync(operation);
        return _catalogTask;
    }

    private async Task RunCatalogOperationAsync(Func<CancellationToken, Task> operation)
    {
        using var cancellation = new CancellationTokenSource();
        _catalogCancellation = cancellation;
        CancelCatalogButton.IsEnabled = true;
        CancelModFolderButton.IsEnabled = true;
        try { await operation(cancellation.Token); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { CatalogProgress.Text = "任务已取消。"; }
        catch (Exception error)
        {
            CatalogProgress.Text = "资源任务未完成。";
            ShowStatus(error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            CancelCatalogButton.IsEnabled = false;
            CancelModFolderButton.IsEnabled = false;
            _catalogCancellation = null;
        }
    }

    private void BeginResourceDownloadCommit(DownloadJob job)
    {
        job.StopOfferingCancel();
        job.Report("正在写入实例目录…");
        CancelCatalogButton.IsEnabled = CancelModFolderButton.IsEnabled = false;
    }

    private void CancelCatalog_Click(object sender, RoutedEventArgs e)
    {
        if (CancelCatalogButton.IsEnabled || CancelModFolderButton.IsEnabled) _catalogCancellation?.Cancel();
    }

    private sealed record CatalogFilters(string Source, string Kind, string Query, GameInstance? Instance, bool Updated);
    private sealed record CatalogEntry(CatalogProject Project, string Note, bool Favorite);
}
