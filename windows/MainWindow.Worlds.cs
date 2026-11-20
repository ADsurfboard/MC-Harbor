using System.Globalization;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private static BridgeClient RequireBridge() =>
        new(JavaRuntimeLocator.FindLauncherJava() ?? throw new BridgeException("找不到随程序提供的 Java 21 运行时。"));

    private static string GameDirectoryKey(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    private string BeginGameDirectoryWrite(GameInstance instance)
    {
        var run = GameDirectoryKey(instance.RunDirectory);
        if (_launchTask is { IsCompleted: false } && _runningGameRunDirectory is { } running
            && string.Equals(run, GameDirectoryKey(running), StringComparison.OrdinalIgnoreCase))
            throw new IOException("此游戏目录正在启动或运行，请退出游戏后再试。");
        EnsureOrdinaryDirectory(run);
        if (!_gameDirectoryWrites.Add(run))
            throw new IOException("此游戏目录有其他文件操作正在进行。");
        return run;
    }

    private static void EnsureOrdinaryDirectory(string path)
    {
        for (DirectoryInfo? directory = new(path); directory is not null; directory = directory.Parent)
        {
            if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("目标路径包含目录联接点或符号链接，请选择实际目录。");
        }
    }

    private static async Task CopyResourceAsync(string file, string run, string kind)
    {
        var directory = Path.Combine(run, kind);
        EnsureOrdinaryDirectory(directory);
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, Path.GetFileName(file));
        var stage = Path.Combine(directory, $".harbor-{Guid.NewGuid():N}.partial");
        try
        {
            await using (var output = new FileStream(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true))
            await using (var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true))
                await input.CopyToAsync(output);
            File.Move(stage, destination);
        }
        finally { if (File.Exists(stage)) File.Delete(stage); }
    }

    private async void BackupWorlds_Click(object sender, RoutedEventArgs e)
    {
        if (_activeModsInstance is { } instance) await BackupWorldAsync(instance, "");
    }

    private async void BackupWorld_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: InstanceResource { Kind: "saves" } world }
            && _activeModsInstance is { } instance)
            await BackupWorldAsync(instance, Path.GetFileName(world.Path));
    }

    private async Task BackupWorldAsync(GameInstance instance, string world)
    {
        try
        {
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                ShowStatus("正在检查并备份存档…", InfoBarSeverity.Informational);
                var result = await RequireBridge().InvokeAsync("backup", new Dictionary<string, object?>
                {
                    ["runDirectory"] = run,
                    ["world"] = world
                }, HandleBridgeEvent);
                ShowStatus($"存档备份完成，已归档 {result["files"]} 个文件。{result["path"]}", InfoBarSeverity.Success);
            }
            finally { _gameDirectoryWrites.Remove(run); }
        }
        catch (Exception error)
        {
            ShowStatus("存档备份失败：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async void EditWorld_Click(object sender, RoutedEventArgs e)
    {
        if (_activeModsInstance is not { } instance
            || sender is not FrameworkElement { DataContext: InstanceResource { Kind: "saves" } world })
            return;

        try
        {
            var run = BeginGameDirectoryWrite(instance);
            try
            {
                var arguments = new Dictionary<string, object?>
                {
                    ["runDirectory"] = run,
                    ["world"] = Path.GetFileName(world.Path)
                };
                var bridge = RequireBridge();
                var snapshot = await bridge.InvokeAsync("worldRead", arguments);
                if (snapshot["players"] is JsonArray { Count: > 1 } players)
                {
                    var rows = players.OfType<JsonObject>()
                        .Select(item => new WorldPlayer(item["id"]!.GetValue<string>(), item["label"]!.GetValue<string>()))
                        .ToArray();
                    var active = snapshot["player"]?.GetValue<string>();
                    var picker = new ComboBox { Header = "玩家", MinWidth = 240, ItemsSource = rows, DisplayMemberPath = nameof(WorldPlayer.Label) };
                    picker.SelectedItem = rows.FirstOrDefault(row => row.Id == active) ?? rows[0];
                    var prompt = new ContentDialog
                    {
                        XamlRoot = RootShell.XamlRoot,
                        Title = "选择要读取的玩家",
                        Content = picker,
                        PrimaryButtonText = "继续",
                        CloseButtonText = "取消",
                        DefaultButton = ContentDialogButton.Primary
                    };
                    if (await prompt.ShowAsync() != ContentDialogResult.Primary) return;
                    if (picker.SelectedItem is WorldPlayer player && player.Id != active)
                    {
                        arguments["player"] = player.Id;
                        snapshot = await bridge.InvokeAsync("worldRead", arguments);
                    }
                }
                await ShowWorldEditorAsync(bridge, arguments, snapshot);
            }
            finally { _gameDirectoryWrites.Remove(run); }
        }
        catch (Exception error)
        {
            ShowStatus("无法编辑存档：" + error.Message, InfoBarSeverity.Error);
        }
    }

    private async Task ShowWorldEditorAsync(BridgeClient bridge, Dictionary<string, object?> arguments, JsonObject snapshot)
    {
        var values = (JsonObject)snapshot["values"]!;
        var form = new StackPanel { Spacing = 10, MinWidth = 300 };
        var readers = new Dictionary<string, Func<JsonNode?>>();
        var errorLabel = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        AddText("name", "世界名称");
        AddChoice("gameMode", "游戏模式", ["生存", "创造", "冒险", "旁观"]);
        AddChoice("difficulty", "难度", ["和平", "简单", "普通", "困难"]);
        AddFlag("hardcore", "极限模式");
        AddFlag("cheats", "允许指令");
        AddNumber("day", "天数", 375299968945L);
        AddNumber("dayTick", "日内时间（0–23999）", 23999L);
        AddNumber("ageTicks", "世界累计时间（刻）", 9007199254740991L);
        AddNumber("health", "生命值", 1000000d);
        AddNumber("hunger", "饱食度（0–20）", 20L);
        AddNumber("saturation", "饱和度（0–20）", 20d);
        AddNumber("xpLevel", "经验等级", 21863L);
        AddNumber("xpProgress", "经验进度（0–0.999999）", 0.999999d);
        if (values["xpTotal"] is { } total)
            form.Children.Add(new TextBlock { Text = $"当前总经验：{total}" });

        form.Children.Add(errorLabel);
        var dialog = new ContentDialog
        {
            XamlRoot = RootShell.XamlRoot,
            Title = $"编辑存档 · {snapshot["world"]}",
            Content = new ScrollViewer { Content = form, MaxHeight = 460 },
            PrimaryButtonText = "备份并保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = readers.Count > 0
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                var changes = new JsonObject();
                foreach (var (key, read) in readers)
                    if (read() is { } edited) changes[key] = edited;
                if (changes.Count == 0) return;
                arguments["player"] = snapshot["player"]?.GetValue<string>() ?? "";
                arguments["revision"] = snapshot["revision"]!.GetValue<string>();
                arguments["changes"] = changes;
                dialog.IsPrimaryButtonEnabled = false;
                var result = await bridge.InvokeAsync("worldSave", arguments);
                ShowStatus($"存档已保存。原始文件备份：{result["backup"]}", InfoBarSeverity.Success);
            }
            catch (Exception error)
            {
                args.Cancel = true;
                errorLabel.Message = error.Message;
                errorLabel.IsOpen = true;
                dialog.IsPrimaryButtonEnabled = true;
            }
            finally { deferral.Complete(); }
        };
        await dialog.ShowAsync();

        void AddText(string key, string label)
        {
            if (values[key] is not { } value) return;
            var original = value.GetValue<string>();
            var box = new TextBox { Header = label, Text = original, MaxLength = 256 };
            readers[key] = () => box.Text.Trim() == original ? null : JsonValue.Create(box.Text.Trim());
            form.Children.Add(box);
        }

        void AddChoice(string key, string label, string[] options)
        {
            if (values[key] is not { } value) return;
            var original = value.GetValue<int>();
            if (original < 0 || original >= options.Length) return;
            var combo = new ComboBox { Header = label, ItemsSource = options, SelectedIndex = original };
            readers[key] = () => combo.SelectedIndex == original ? null : JsonValue.Create(combo.SelectedIndex);
            form.Children.Add(combo);
        }

        void AddFlag(string key, string label)
        {
            if (values[key] is not { } value) return;
            var original = value.GetValue<int>() != 0;
            var check = new CheckBox { Content = label, IsChecked = original };
            readers[key] = () => check.IsChecked == original ? null : JsonValue.Create(check.IsChecked == true ? 1 : 0);
            form.Children.Add(check);
        }

        void AddNumber(string key, string label, double maximum)
        {
            if (values[key] is not { } value) return;
            var original = value.ToJsonString();
            var box = new TextBox { Header = label, Text = original, MaxLength = 32 };
            readers[key] = () =>
            {
                var text = box.Text.Trim();
                if (text == original) return null;
                if (maximum == Math.Truncate(maximum) && key is not ("health" or "saturation"))
                {
                    if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number)
                        && number >= 0 && number <= maximum)
                        return JsonValue.Create(number);
                }
                else if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
                    && double.IsFinite(number) && number >= 0 && number <= maximum)
                    return JsonValue.Create(number);
                throw new IOException($"{label}的数值无效。");
            };
            form.Children.Add(box);
        }
    }

    private sealed record WorldPlayer(string Id, string Label);
}
