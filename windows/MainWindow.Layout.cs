using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private string _settingsSection = "appearance";
    private string _resourceCategory = "mods";
    private InstanceResource[] _instanceResources = [];

    private static Visibility VisibleWhen(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    private void CardGrid_Loaded(object sender, RoutedEventArgs e) => ResizeCardGrid((GridView)sender);

    private void CardGrid_SizeChanged(object sender, SizeChangedEventArgs e) => ResizeCardGrid((GridView)sender);

    private void ResizeCardGrid(GridView view)
    {
        if (view.ActualWidth <= 1 || view.ItemsPanelRoot is not ItemsWrapGrid panel) return;
        var library = view == InstanceList;
        var gap = library ? 14 : 20;
        var minimum = library ? 300 : 250;
        var width = Math.Max(1, view.ActualWidth - gap - 2);
        var columns = Math.Max(1, (int)((width + gap) / (minimum + gap)));
        panel.MaximumRowsOrColumns = columns;
        panel.ItemWidth = (width + gap) / columns;
        if (library) LibraryGridHeader.Width = width;
    }

    private void UpdatePageSelections()
    {
        UpdateTabSelection(DownloadCategories, _downloadCategory);
        UpdateTabSelection(VersionFilters, _versionFilter);
        UpdateTabSelection(SettingsSections, _settingsSection);
        UpdateTabSelection(WorkspaceTabs, _lastNavigationTag is "localization" or "instance-settings"
            ? _lastNavigationTag : _resourceCategory);
    }

    private void UpdateTabSelection(StackPanel group, string? current)
    {
        var selectedFill = _chromeHighContrast
            ? _uiSettings.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.Highlight)
            : _darkAppearance ? global::Windows.UI.Color.FromArgb(34, 255, 255, 255)
            : global::Windows.UI.Color.FromArgb(24, 22, 22, 22);
        foreach (var button in group.Children.OfType<Button>())
        {
            var selected = Equals(button.Tag, current);
            button.Background = new SolidColorBrush(selected ? selectedFill : Microsoft.UI.Colors.Transparent);
            button.BorderBrush = new SolidColorBrush(selected
                ? (_chromeHighContrast ? selectedFill : _glassBorder.Color) : Microsoft.UI.Colors.Transparent);
            if (_chromeHighContrast && selected)
                button.Foreground = new SolidColorBrush(_uiSettings.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.HighlightText));
            else button.ClearValue(Control.ForegroundProperty);
            AutomationProperties.SetItemStatus(button, selected ? "当前分类" : "");
        }
    }

    private void SettingsSection_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string section })
        {
            SettingsSearch.Text = "";
            SelectSettingsSection(section);
        }
    }

    private void SelectSettingsSection(string section, FrameworkElement? target = null)
    {
        _settingsSection = section;
        AppearanceSettings.Visibility = VisibleWhen(section == "appearance");
        WelcomeSettings.Visibility = VisibleWhen(section == "welcome");
        RuntimeSettings.Visibility = VisibleWhen(section == "runtime");
        MaintenanceSettings.Visibility = VisibleWhen(section == "maintenance");
        UpdateTabSelection(SettingsSections, section);
        if (target is null) SettingsScroll.ChangeView(null, 0, null, disableAnimation: true);
        else DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () => target.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0 }));
        QueueGlassCardsRefresh();
    }

    private (string Label, string Terms, string Section, FrameworkElement Target)[] SettingsIndex() =>
    [
        ("外观 · 玻璃与主题", "主题 反色 磨砂 毛玻璃 玻璃通透度 玻璃透明度 玻璃阴影强度 模糊 半径 性能 动效", "appearance", SettingsGlass),
        ("外观 · 启动器壁纸", "壁纸库 图片 视频 MP4 预览 重命名 调暗 柔化", "appearance", SettingsWallpaper),
        ("外观 · 界面音效", "音效 声音 音量", "appearance", SettingsSounds),
        ("欢迎动画 · 启动播报", "欢迎 语音 播报 静音 音量 试听", "welcome", SettingsVoice),
        ("运行 · 游戏目录", "目录 路径 Minecraft", "runtime", SettingsPaths),
        ("运行 · 游戏与下载", "内存 下载 镜像 模组 依赖", "runtime", SettingsGameOptions),
        ("维护 · 数据目录与诊断", "诊断 数据 历史 游玩 存储", "maintenance", SettingsData)
    ];

    private void SettingsSearch_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            sender.ItemsSource = FindSettings(sender.Text).Select(item => item.Label).ToArray();
    }

    private void SettingsSearch_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs e)
    {
        var matches = e.ChosenSuggestion is string chosen ? SettingsIndex().Where(item => item.Label == chosen)
            : FindSettings(e.QueryText);
        var match = matches.FirstOrDefault();
        if (match.Target is null)
        {
            if (!string.IsNullOrWhiteSpace(e.QueryText)) ShowStatus("没有匹配的设置。", InfoBarSeverity.Informational);
            return;
        }
        CloseStatus();
        sender.Text = "";
        SelectSettingsSection(match.Section, match.Target);
    }

    private IEnumerable<(string Label, string Terms, string Section, FrameworkElement Target)> FindSettings(string query)
    {
        query = query.Trim();
        return query.Length == 0 ? [] : SettingsIndex().Where(item =>
            item.Label.Contains(query, StringComparison.OrdinalIgnoreCase) || item.Terms.Contains(query, StringComparison.OrdinalIgnoreCase));
    }

    private void UpdateWorkspaceHeader()
    {
        var show = IsInstancePage(_lastNavigationTag) && _activeModsInstance is not null;
        WorkspaceIcon.Visibility = WorkspaceTabs.Visibility = WorkspaceTopActions.Visibility = VisibleWhen(show);
        if (!show || _activeModsInstance is not { } instance) return;
        PageTitle.Text = instance.Id;
        PageTitle.FontSize = 27;
        PageSubtitle.Text = $"{instance.Version} · {instance.Loader}";
        PageSubtitle.Visibility = Visibility.Visible;
        WorkspaceIcon.Source = new BitmapImage(new Uri(instance.Artwork));
        InstanceSettingsPath.Text = instance.RunDirectory;
        WorkspaceLaunchButton.Tag = WorkspaceOpenDirectory.Tag = WorkspaceRepair.Tag = WorkspaceExport.Tag =
            WorkspaceRelocate.Tag = WorkspaceJava.Tag = WorkspaceChangeIcon.Tag = WorkspaceShortcut.Tag = instance.Id;
        UpdateFeaturedLaunch();
    }

    private void WorkspaceTab_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tab } || _activeModsInstance is null) return;
        if (tab is "localization" or "instance-settings") NavigateTo(tab);
        else
        {
            _resourceCategory = tab;
            ResourceQuery.Text = "";
            if (_lastNavigationTag == "collections") UpdateResourceRows();
            else NavigateTo("collections");
        }
    }

    private void CloseWorkspace_Click(object sender, RoutedEventArgs e) => NavigateTo("games");

    private void ResourceQuery_Changed(object sender, TextChangedEventArgs e)
    {
        if (ResourceCount is not null) UpdateResourceRows();
    }

    private void UpdateResourceRows()
    {
        var query = ResourceQuery.Text.Trim();
        var items = _instanceResources.Where(item => item.Kind == _resourceCategory
            && (item.Name.Contains(query, StringComparison.OrdinalIgnoreCase)
                || Path.GetFileName(item.Path).Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        ResourcesList.ItemsSource = items;
        ResourceCount.Text = items.Length == 0 ? "没有匹配的项目" : $"{items.Length} 个项目";
        ResourceImportButton.Content = _resourceCategory switch
        {
            "resourcepacks" => "导入资源包",
            "shaderpacks" => "导入光影",
            "saves" => "导入地图",
            _ => "导入模组"
        };
        CollectWorkspaceMods.Visibility = VisibleWhen(_resourceCategory == "mods");
        BackupWorkspaceWorlds.Visibility = VisibleWhen(_resourceCategory == "saves");
        UpdateTabSelection(WorkspaceTabs, _resourceCategory);
    }

    private async void RefreshWorkspaceResources_Click(object sender, RoutedEventArgs e) => await LoadResourcesAsync();

    private void BrowseWorkspaceResources_Click(object sender, RoutedEventArgs e)
    {
        var category = _resourceCategory switch
        {
            "resourcepacks" => "resourcepack",
            "shaderpacks" => "shader",
            "saves" => "world",
            _ => "mod"
        };
        OpenDownloads(category, _activeModsInstance);
    }
}
