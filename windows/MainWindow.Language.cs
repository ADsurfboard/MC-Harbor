using System.Globalization;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private const int LanguagePageSize = 200;
    private GameInstance? _languageInstance;
    private string? _languageProject;
    private LanguageSource[] _languageSources = [];
    private int _languageOffset;
    private int _languageReadSequence;
    private double _languagePackFormat;
    private bool _languageBusy;
    private bool _settingLanguageSelection;
    private bool _resumeAfterGame;
    private CancellationTokenSource? _languageTranslation;
    private Task? _languageTranslationTask;
    private string[]? _pausedTranslationScope;

    private void PrepareLanguageWorkspace()
    {
        var previous = LanguageInstance.SelectedItem as GameInstance;
        var current = _instances.FirstOrDefault(item => _activeModsInstance is not null
                && item.Id == _activeModsInstance.Id && item.Directory == _activeModsInstance.Directory)
            ?? _instances.FirstOrDefault(item => previous is not null && item.Id == previous.Id && item.Directory == previous.Directory)
            ?? _instances.FirstOrDefault();
        _settingLanguageSelection = true;
        LanguageInstance.ItemsSource = _instances.ToArray();
        LanguageInstance.SelectedItem = current;
        _settingLanguageSelection = false;
        if (!Equals(current, _languageInstance) && !_languageBusy) _ = OpenLanguageAsync(current);
    }

    private async void LanguageInstance_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_settingLanguageSelection && !_languageBusy)
            await OpenLanguageAsync(LanguageInstance.SelectedItem as GameInstance);
    }

    private async Task OpenLanguageAsync(GameInstance? instance)
    {
        _languageInstance = instance;
        ResetLanguageWorkspace();
        if (instance is null)
        {
            LanguageSummary.Text = "在游戏库中安装或导入实例后，即可扫描文字。";
            return;
        }
        await LanguageOperationAsync(async () =>
        {
            var result = await RequireBridge().InvokeAsync("langOpen", InstanceLanguageArguments(instance));
            if (result["project"] is JsonObject { Count: > 0 } project)
            {
                SetLanguageProject(project);
                await ReadLanguagePageAsync(0);
            }
            else
            {
                LanguageSummary.Text = "扫描实例以读取模组、资源包、任务和数据包文字。";
            }
        });
    }

    private void ResetLanguageWorkspace()
    {
        ++_languageReadSequence;
        _languageProject = null;
        _languageSources = [];
        _languagePackFormat = 0;
        SetLanguageControls(LanguageActions, enabled: false);
        LanguageSources.ItemsSource = null;
        LanguageEntries.ItemsSource = null;
        _languageOffset = 0;
        LanguagePage.Text = "";
        PreviousLanguagePage.IsEnabled = NextLanguagePage.IsEnabled = false;
    }

    private async void ScanLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (_languageInstance is not { } instance) return;
        await LanguageOperationAsync(async () =>
        {
            ShowStatus("正在扫描实例文字…", InfoBarSeverity.Informational);
            var project = await RequireBridge().InvokeAsync("langScan", InstanceLanguageArguments(instance), HandleBridgeEvent);
            SetLanguageProject(project);
            await ReadLanguagePageAsync(0);
            ShowStatus($"扫描完成，找到 {_languageSources.Length} 个文字来源。", InfoBarSeverity.Success);
        });
    }

    private void SetLanguageProject(JsonObject project)
    {
        var previous = (LanguageSources.SelectedItem as LanguageSource)?.Id;
        _languageProject = project["project"]?.GetValue<string>();
        _languagePackFormat = project["packFormat"]?.GetValue<double>() ?? 0;
        _languageSources = (project["sources"] as JsonArray)?.OfType<JsonObject>()
            .Select(row => new LanguageSource(
                row["id"]!.GetValue<string>(),
                row["name"]?.GetValue<string>() ?? "",
                row["enabled"]?.GetValue<bool>() ?? true,
                row["entries"]?.GetValue<int>() ?? 0,
                row["translated"]?.GetValue<int>() ?? 0))
            .Where(source => source.Entries > 0)
            .ToArray() ?? [];
        _settingLanguageSelection = true;
        LanguageSources.ItemsSource = _languageSources;
        LanguageSources.SelectedItem = _languageSources.FirstOrDefault(item => item.Id == previous)
            ?? _languageSources.FirstOrDefault(source => source.Enabled)
            ?? _languageSources.FirstOrDefault();
        _settingLanguageSelection = false;
        var warnings = (project["warnings"] as JsonArray)?.Count ?? 0;
        LanguageSummary.Text = $"{_languageSources.Length} 个来源 · {_languageSources.Sum(item => item.Translated)} / {_languageSources.Sum(item => item.Entries)} 条已有译文"
            + (warnings > 0 ? $" · {warnings} 个扫描提示" : "");
        if (warnings > 0)
            ToolTipService.SetToolTip(LanguageSummary, string.Join("\n", project["warnings"]!.AsArray().Take(10)));
        else
            ToolTipService.SetToolTip(LanguageSummary, null);
        SetLanguageControls(LanguageActions, !_languageBusy && _languageSources.Length > 0);
    }

    private async void LanguageSources_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_settingLanguageSelection && !_languageBusy) await LanguageOperationAsync(() => ReadLanguagePageAsync(0));
    }

    private async void FilterLanguage_Click(object sender, RoutedEventArgs e) =>
        await LanguageOperationAsync(() => ReadLanguagePageAsync(0));

    private async void PreviousLanguagePage_Click(object sender, RoutedEventArgs e) =>
        await LanguageOperationAsync(() => ReadLanguagePageAsync(Math.Max(0, _languageOffset - LanguagePageSize)));

    private async void NextLanguagePage_Click(object sender, RoutedEventArgs e) =>
        await LanguageOperationAsync(() => ReadLanguagePageAsync(_languageOffset + LanguagePageSize));

    private async Task ReadLanguagePageAsync(int offset)
    {
        var sequence = ++_languageReadSequence;
        if (_languageProject is null || LanguageSources.SelectedItem is not LanguageSource source)
        {
            LanguageEntries.ItemsSource = null;
            return;
        }
        var previous = (LanguageEntries.SelectedItem as LanguageEntry)?.Id;
        var arguments = ProjectLanguageArguments();
        arguments["resource"] = source.Id;
        arguments["offset"] = offset;
        arguments["pageSize"] = LanguagePageSize;
        arguments["query"] = LanguageQuery.Text.Trim();
        arguments["missing"] = OnlyMissingLanguage.IsChecked == true;
        var result = await RequireBridge().InvokeAsync("langRead", arguments);
        if (sequence != _languageReadSequence) return;
        var rows = (result["entries"] as JsonArray)?.OfType<JsonObject>().Select(row => new LanguageEntry(
            row["id"]!.GetValue<string>(), row["key"]?.GetValue<string>() ?? "",
            row["source"]?.GetValue<string>() ?? "", row["translation"]?.GetValue<string>() ?? "",
            row["origin"]?.GetValue<string>() ?? "", row["issue"]?.GetValue<string>() ?? "")).ToArray() ?? [];
        _languageOffset = result["offset"]?.GetValue<int>() ?? 0;
        var total = result["total"]?.GetValue<int>() ?? 0;
        LanguageEntries.ItemsSource = rows;
        LanguageEntries.SelectedItem = rows.FirstOrDefault(row => row.Id == previous);
        LanguagePage.Text = total == 0 ? "没有符合条件的条目" : $"{_languageOffset + 1}–{_languageOffset + rows.Length} / {total}";
        PreviousLanguagePage.IsEnabled = _languageOffset > 0;
        NextLanguagePage.IsEnabled = _languageOffset + rows.Length < total;
    }

    private void LanguageEntries_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var entry = LanguageEntries.SelectedItem as LanguageEntry;
        LanguageEntryEdit.Visibility = entry is null ? Visibility.Collapsed : Visibility.Visible;
        if (entry is null) return;
        LanguageOriginal.Text = entry.Source;
        LanguageDraft.Text = entry.Translation;
        LanguageEntryStatus.Text = entry.Issue.Length > 0 ? entry.Issue : entry.Origin switch
        {
            "embedded" => "资源内译文",
            "manual" => "人工译文",
            "machine" => "本机补译",
            "online" => "在线补译",
            "community" => "社区译文",
            _ => "待译"
        };
    }

    private async void SaveLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (LanguageSources.SelectedItem is not LanguageSource source
            || LanguageEntries.SelectedItem is not LanguageEntry entry) return;
        var translation = LanguageDraft.Text;
        await LanguageOperationAsync(async () =>
        {
            var arguments = ProjectLanguageArguments();
            arguments["resource"] = source.Id;
            arguments["entry"] = entry.Id;
            arguments["translation"] = translation;
            var result = await RequireBridge().InvokeAsync("langSave", arguments);
            if (result["project"] is JsonObject project) SetLanguageProject(project);
            await ReadLanguagePageAsync(_languageOffset);
            ShowStatus("译文已保存。", InfoBarSeverity.Success);
        });
    }

    private async void CommunityLanguage_Click(object sender, RoutedEventArgs e) =>
        await LanguageOperationAsync(async () =>
        {
            var arguments = SelectedLanguageArguments();
            ShowStatus("正在读取 CFPA 社区译库…", InfoBarSeverity.Informational);
            var result = await RequireBridge().InvokeAsync("langTranslate", arguments);
            if (result["project"] is JsonObject project) SetLanguageProject(project);
            await ReadLanguagePageAsync(_languageOffset);
            var warning = (result["warnings"] as JsonArray)?.FirstOrDefault()?.GetValue<string>();
            ShowStatus(warning ?? $"社区译库已补全 {result["filled"]} 条译文。",
                warning is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning);
        });

    private async void ImportLanguage_Click(object sender, RoutedEventArgs e) =>
        await LanguageOperationAsync(async () =>
        {
            var arguments = SelectedLanguageArguments();
            var file = await PickFileAsync(".zip", ".json", ".lang");
            if (file is null) return;
            arguments["file"] = file.Path;
            var result = await RequireBridge().InvokeAsync("langImport", arguments);
            if (result["project"] is JsonObject project) SetLanguageProject(project);
            await ReadLanguagePageAsync(_languageOffset);
            ShowStatus($"已导入 {result["imported"]} 条译文，{result["rejected"]} 条格式不符。", InfoBarSeverity.Success);
        });

    private async void ExportLanguage_Click(object sender, RoutedEventArgs e) => await ExportLanguageAsync(false);
    private async void ExportLanguageSource_Click(object sender, RoutedEventArgs e) => await ExportLanguageAsync(true);

    private Task ExportLanguageAsync(bool sourceOnly) => LanguageOperationAsync(async () =>
    {
        var arguments = SelectedLanguageArguments();
        var folder = await PickFolderAsync();
        if (folder is null) return;
        var packName = new TextBox { Header = "资源包名称", Text = $"{_languageInstance?.Id} 汉化", MaxLength = 150 };
        var filename = new TextBox { Header = "新 ZIP 文件名", Text = sourceOnly ? "MC-Harbor-原文.zip" : "MC-Harbor-汉化.zip", MaxLength = 140 };
        var format = new TextBox
        {
            Header = "资源包格式号",
            Text = _languagePackFormat > 0 ? _languagePackFormat.ToString(CultureInfo.InvariantCulture) : ""
        };
        var dialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = sourceOnly ? "导出待翻译模板" : "导出汉化资源包",
            Content = new StackPanel { Spacing = 8, Children = { packName, filename, format } },
            PrimaryButtonText = "导出",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var name = filename.Text.Trim();
        if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) name += ".zip";
        if (!IsSafeInstanceName(name)) throw new IOException("请输入有效的新 ZIP 文件名。");
        if (!double.TryParse(format.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
            || !double.IsFinite(number) || number is <= 0 or > 10000)
            throw new IOException("请输入有效的资源包格式号。");
        arguments["output"] = Path.Combine(folder.Path, name);
        arguments["packName"] = packName.Text.Trim();
        arguments["packFormat"] = number;
        arguments["mode"] = sourceOnly ? "source" : "translated";
        var result = await RequireBridge().InvokeAsync("langExport", arguments);
        ShowStatus($"已导出 {result["entries"]} 条文字。{result["path"]}", InfoBarSeverity.Success);
    });

    private async void ApplyLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (_languageInstance is not { } instance) return;
        await LanguageOperationAsync(async () =>
        {
            var arguments = SelectedLanguageArguments();
            var dialog = new ContentDialog
            {
                XamlRoot = RootShell.XamlRoot,
                Title = "应用任务和数据包译文",
                Content = "保存前会校验原文件并生成原件备份。请先退出游戏。",
                PrimaryButtonText = "备份并应用",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                var result = await RequireBridge().InvokeAsync("langApply", arguments);
                var count = result["files"]?.GetValue<int>() ?? 0;
                ShowStatus(count == 0 ? "没有可应用的任务或数据包译文。"
                    : $"已应用 {count} 个文件。备份：{result["backup"]}", InfoBarSeverity.Success);
            }
            finally { _gameDirectoryWrites.Remove(run); }
        });
    }

    private Dictionary<string, object?> ProjectLanguageArguments()
    {
        if (_languageInstance is not { } instance || _languageProject is null)
            throw new IOException("请先扫描实例。");
        var arguments = InstanceLanguageArguments(instance);
        arguments["project"] = _languageProject;
        return arguments;
    }

    private Dictionary<string, object?> SelectedLanguageArguments()
    {
        var arguments = ProjectLanguageArguments();
        var selected = LanguageScope.SelectedIndex == 1
            ? LanguageSources.SelectedItem is LanguageSource source ? new[] { source.Id } : []
            : _languageSources.Where(source => source.Enabled).Select(source => source.Id).ToArray();
        if (selected.Length == 0) throw new IOException("此范围没有可用的文字来源。");
        arguments["selected"] = selected;
        return arguments;
    }

    private static Dictionary<string, object?> InstanceLanguageArguments(GameInstance instance) => new()
    {
        ["id"] = instance.Id,
        ["name"] = instance.Id,
        ["version"] = instance.Version,
        ["loader"] = instance.Loader,
        ["runDirectory"] = instance.RunDirectory
    };

    private async Task LanguageOperationAsync(Func<Task> operation)
    {
        if (_languageBusy) return;
        _languageBusy = true;
        SetLanguageControls(LanguageActions, enabled: false);
        SetLanguageControls(LanguageScanSelectors, enabled: false);
        LanguageEditor.IsHitTestVisible = false;
        LanguageSources.IsEnabled = LanguageEntries.IsEnabled = LanguageQuery.IsEnabled = LanguageDraft.IsEnabled = false;
        try { await operation(); }
        catch (Exception error) { ShowStatus("汉化操作失败：" + error.Message, InfoBarSeverity.Error); }
        finally
        {
            _languageBusy = false;
            SetLanguageControls(LanguageScanSelectors, enabled: true);
            LanguageEditor.IsHitTestVisible = true;
            LanguageSources.IsEnabled = LanguageEntries.IsEnabled = LanguageQuery.IsEnabled = LanguageDraft.IsEnabled = true;
            SetLanguageControls(LanguageActions, _languageSources.Length > 0);
        }
    }

    private static void SetLanguageControls(Panel panel, bool enabled)
    {
        foreach (var control in panel.Children.OfType<Control>()) control.IsEnabled = enabled;
    }
}
