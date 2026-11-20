using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private ModFolder? _selectedModFolder;

    private void RefreshModFolders(Guid? selected = null)
    {
        try
        {
            var folders = ModFolderStore.Read();
            selected ??= _selectedModFolder?.Id;
            _selectedModFolder = folders.FirstOrDefault(folder => folder.Id == selected);
            ModFolderCards.ItemsSource = folders;
            UpdateModFolderTargets();
            UpdateModFolderLayout();
            ShowModFolderEntries();
        }
        catch (Exception error) { ShowStatus("读取模组夹失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private void ModFolderCard_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ModFolder folder) return;
        _selectedModFolder = folder;
        ModFolderQuery.Text = "";
        ShowModFolderEntries();
        UpdateModFolderLayout();
    }

    private void CloseModFolder_Click(object sender, RoutedEventArgs e) => CloseModFolderDetail();

    private void CloseModFolderDetail()
    {
        _selectedModFolder = null;
        ModFolderQuery.Text = "";
        UpdateModFolderLayout();
    }

    private void UpdateModFolderLayout()
    {
        var browse = _selectedModFolder is null;
        ModFolderCards.Visibility = VisibleWhen(browse);
        NewModFolderButton.Visibility = VisibleWhen(browse && _lastNavigationTag == "modfolders");
        ModFolderDetail.Visibility = VisibleWhen(!browse);
        ModFoldersEmpty.Visibility = VisibleWhen(browse && ModFolderCards.Items.Count == 0);
        QueueGlassCardsRefresh();
    }

    private void UpdateModFolderTargets()
    {
        var previous = (ModFolderTarget.SelectedItem as GameInstance)?.Directory
            ?? (InstanceList.SelectedItem as GameInstance)?.Directory;
        var targets = _instances.Where(instance => ResourceCatalog.Loader(instance) is not null).ToArray();
        ModFolderTarget.ItemsSource = targets;
        ModFolderTarget.SelectedItem = targets.FirstOrDefault(instance => instance.Directory == previous) ?? targets.FirstOrDefault();
    }

    private void ModFolderQuery_Changed(object sender, TextChangedEventArgs e) => ShowModFolderEntries();

    private void ShowModFolderEntries()
    {
        if (ModFolderStatus is null) return;
        var query = ModFolderQuery.Text.Trim();
        var folder = _selectedModFolder;
        ModFolderTitle.Text = folder?.Name ?? "";
        ModFolderEntries.ItemsSource = folder?.Entries.Where(entry => entry.Name.Contains(query, StringComparison.OrdinalIgnoreCase)
            || entry.Details.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        ModFolderStatus.Text = folder is null ? "新建模组夹后可收藏本地或在线模组。" : $"{folder.Entries.Length} 个模组";
    }

    private async void CreateModFolder_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            var folder = await PromptFolderNameAsync(null, cancellation);
            if (folder is null) return;
            ModFolderStore.Write([..ModFolderStore.Read(), folder]);
            RefreshModFolders(folder.Id);
        });

    private async void RenameModFolder_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            if (_selectedModFolder is not { } current) return;
            var updated = await PromptFolderNameAsync(current, cancellation);
            if (updated is null) return;
            ModFolderStore.Write(ModFolderStore.Read().Select(folder => folder.Id == updated.Id ? updated : folder).ToArray());
            RefreshModFolders(updated.Id);
        });

    private async Task<ModFolder?> PromptFolderNameAsync(ModFolder? current, CancellationToken cancellation)
    {
        var input = new TextBox { Header = "名称", Text = current?.Name ?? "", MaxLength = 60, MinWidth = 240 };
        var dialog = FriendDialog(current is null ? "新建模组夹" : "重命名模组夹", input, "保存");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        cancellation.ThrowIfCancellationRequested();
        var name = input.Text.Trim();
        if (name.Length == 0 || name.Any(char.IsControl)) throw new IOException("请填写有效的模组夹名称。");
        return current is null ? new ModFolder(Guid.NewGuid(), name, []) : current with { Name = name };
    }

    private async void DeleteModFolder_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            if (_selectedModFolder is not { } current) return;
            var dialog = FriendDialog($"删除「{current.Name}」？",
                new TextBlock { Text = "删除此收藏列表。", TextWrapping = TextWrapping.Wrap }, "删除");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            cancellation.ThrowIfCancellationRequested();
            ModFolderStore.Write(ModFolderStore.Read().Where(folder => folder.Id != current.Id).ToArray());
            CloseModFolderDetail();
            RefreshModFolders();
        });

    private async void RemoveFolderMods_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(cancellation =>
        {
            if (_selectedModFolder is not { } current) return Task.CompletedTask;
            var ids = ModFolderEntries.SelectedItems.OfType<ModFolderEntry>().Select(entry => entry.Id).ToHashSet();
            if (ids.Count == 0) return Task.CompletedTask;
            UpdateModFolder(current.Id, entries => entries.Where(entry => !ids.Contains(entry.Id)).ToArray());
            return Task.CompletedTask;
        });

    private async Task<ModFolder?> PickModFolderAsync(CancellationToken cancellation)
    {
        var folders = ModFolderStore.Read();
        if (folders.Length == 0)
        {
            var created = await PromptFolderNameAsync(null, cancellation);
            if (created is not null) ModFolderStore.Write([created]);
            return created;
        }
        var picker = new ComboBox { Header = "目标模组夹", ItemsSource = folders, DisplayMemberPath = nameof(ModFolder.Name),
            SelectedIndex = 0, MinWidth = 240 };
        var dialog = FriendDialog("加入模组夹", picker, "收藏");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        cancellation.ThrowIfCancellationRequested();
        return picker.SelectedItem as ModFolder;
    }

    private async void CollectLocalFile_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            if (_selectedModFolder is not { } folder) throw new IOException("请先打开一个模组夹。");
            var picked = await PickFileAsync(".jar");
            if (picked is null) return;
            if (!IsSafeFileName(picked.Name)) throw new IOException("模组文件名在 Windows 上不可用。");
            var item = await ModFolderStore.CollectAsync(picked.Path, picked.DisplayName, null, null, cancellation);
            AddFolderMods(folder, [item]);
        });

    private async void CollectInstanceMods_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            if (_activeModsInstance is not { } instance) return;
            var mods = ResourcesList.SelectedItems.OfType<InstanceResource>().Where(resource => resource.Kind == "mods").ToArray();
            if (mods.Length == 0) throw new IOException("请在列表里选中要收藏的模组。");
            var folder = await PickModFolderAsync(cancellation);
            if (folder is null) return;
            var entries = new List<ModFolderEntry>();
            var root = Path.GetFullPath(Path.Combine(instance.RunDirectory, "mods"));
            EnsureOrdinaryDirectory(root);
            foreach (var mod in mods)
            {
                var path = Path.GetFullPath(mod.Path);
                if (!string.Equals(Path.GetDirectoryName(path), root, StringComparison.OrdinalIgnoreCase)
                    || !IsSafeFileName(Path.GetFileName(path))) throw new IOException("模组路径无效，请刷新实例资源。");
                entries.Add(await ModFolderStore.CollectAsync(path, mod.Name, instance.Version, instance.Loader, cancellation));
            }
            AddFolderMods(folder, entries);
        });

    private async void CollectMarketMod_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            if (CatalogResults.SelectedItem is not CatalogProject { Kind: "mod" } project)
                throw new IOException("请选择一个模组项目。");
            var folder = await PickModFolderAsync(cancellation);
            if (folder is null) return;
            AddFolderMods(folder, [new ModFolderEntry($"{project.Source}:{project.Id}", project.Name, null, project, null, null)]);
        });

    private void AddFolderMods(ModFolder folder, IEnumerable<ModFolderEntry> entries)
    {
        var added = 0;
        UpdateModFolder(folder.Id, current =>
        {
            var updated = current.Concat(entries).DistinctBy(entry => entry.Id).ToArray();
            added = updated.Length - current.Length;
            return updated;
        });
        var status = added > 0 ? $"「{folder.Name}」已收藏 {added} 个新模组。" : $"「{folder.Name}」已有这些模组。";
        ModFolderStatus.Text = status;
        ShowStatus(status, InfoBarSeverity.Success);
    }

    private void UpdateModFolder(Guid id, Func<ModFolderEntry[], ModFolderEntry[]> change)
    {
        var folders = ModFolderStore.Read();
        var index = Array.FindIndex(folders, folder => folder.Id == id);
        if (index < 0) throw new IOException("模组夹已不存在。");
        var current = folders[index];
        folders[index] = current with { Entries = change(current.Entries) };
        ModFolderStore.Write(folders);
        if (ModFoldersPage.Visibility == Visibility.Visible) RefreshModFolders();
    }

    private async void InstallFolderMods_Click(object sender, RoutedEventArgs e) =>
        await CatalogOperationAsync(async cancellation =>
        {
            var selected = ModFolderEntries.SelectedItems.OfType<ModFolderEntry>().ToArray();
            if (selected.Length == 0) throw new IOException("请选择要导入的模组。");
            if (ModFolderTarget.SelectedItem is not GameInstance target)
                throw new IOException("请选择一个已安装模组加载器的目标实例。");
            var detail = new TextBlock { Text = $"安装到 {target.Id}。", TextWrapping = TextWrapping.Wrap };
            if (selected.Any(item => item.Project is null))
                detail.Text += "\n请确认本地 JAR 适用于所选 Minecraft 版本和加载器。";
            var dialog = FriendDialog($"导入 {selected.Length} 个模组", detail, "导入");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            cancellation.ThrowIfCancellationRequested();
            await RunResourceDownloadAsync($"导入 {selected.Length} 个模组到 {target.Id}", ModFolderStatus, cancellation,
                job => InstallModFolderSelectionAsync(selected, target, job, cancellation));
        });

    private async Task InstallModFolderSelectionAsync(ModFolderEntry[] selected, GameInstance instance, DownloadJob job,
        CancellationToken cancellation)
    {
        ModFolderStatus.Text = "正在准备模组…";
        var catalog = new ResourceCatalog(RequireBridge());
        var plans = new Dictionary<string, (CatalogFile File, ModFolderEntry? Local)>(StringComparer.OrdinalIgnoreCase);
        var versions = new Dictionary<(string Source, string Project), string>();
        foreach (var item in selected)
        {
            cancellation.ThrowIfCancellationRequested();
            if (item.Project is not { } project)
            {
                var name = item.FileName ?? "";
                AddFile(new CatalogFile(name, "", 0, true, []), item);
                continue;
            }
            if (versions.ContainsKey((project.Source, project.Id))) continue;
            var version = (await catalog.VersionsAsync(project, instance, cancellation)).FirstOrDefault()
                ?? throw new IOException($"「{item.Name}」没有适用版本。");
            foreach (var file in await catalog.PlanAsync(project, version, instance, cancellation))
            {
                var key = (project.Source, file.Project);
                if (versions.TryGetValue(key, out var previous))
                {
                    if (previous != file.Version) throw new IOException("所选模组要求不同的依赖版本。");
                    continue;
                }
                versions.Add(key, file.Version);
                AddFile(file, null);
            }
        }
        var stage = Path.Combine(AppPaths.DataDirectory, "download-staging", Guid.NewGuid().ToString("N"));
        EnsureOrdinaryDirectory(stage);
        Directory.CreateDirectory(stage);
        try
        {
            foreach (var (file, local) in plans.Values)
            {
                ModFolderStatus.Text = $"正在准备 {file.Name}";
                job.Report(ModFolderStatus.Text);
                var destination = Path.Combine(stage, file.Name);
                if (local is null) await catalog.DownloadAsync(file, destination, cancellation);
                else await ModFolderStore.CopyToAsync(local, destination, cancellation);
            }
            await WaitForGameDirectoryAsync(instance, ModFolderStatus, job, cancellation);
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                BeginResourceDownloadCommit(job);
                await CommitCatalogFilesAsync(run, "mod", stage, plans.Values.Select(item => item.File).ToArray(), "");
            }
            finally { _gameDirectoryWrites.Remove(run); }
            ModFolderStatus.Text = $"已将所选模组导入 {instance.Id}。";
            if (_activeModsInstance == instance) await LoadResourcesAsync();
        }
        finally
        {
            foreach (var name in plans.Keys) File.Delete(Path.Combine(stage, name));
            Directory.Delete(stage);
        }

        void AddFile(CatalogFile file, ModFolderEntry? local)
        {
            if (!IsSafeFileName(file.Name) || !file.Name.EndsWith(".jar", StringComparison.OrdinalIgnoreCase))
                throw new IOException("模组文件名在 Windows 上不可用。");
            if (!plans.TryAdd(file.Name, (file, local)))
                throw new IOException($"多个模组使用相同的文件名：{file.Name}");
        }
    }
}
