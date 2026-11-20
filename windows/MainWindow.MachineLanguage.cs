using System.Text.Json.Nodes;
using MCHarbor.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private async void MachineLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (_languageBusy || _languageTranslationTask is { IsCompleted: false }) return;
        if (_launchTask is { IsCompleted: false })
        {
            ShowStatus("游戏正在运行。退出后即可开始本机补译。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            var arguments = SelectedLanguageArguments();
            if (!LocalTranslationWorker.ModelIsReady)
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = RootShell.XamlRoot,
                    Title = "准备本机补译",
                    Content = "首次使用会下载约 325 MB 的英译中模型和运行库，需要约 1 GB 临时空间。配置完成后，翻译在本机执行。",
                    PrimaryButtonText = "下载并开始",
                    CloseButtonText = "取消",
                    DefaultButton = ContentDialogButton.Primary
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            }
            if (_launchTask is { IsCompleted: false } || _languageBusy) return;
            _pausedTranslationScope = arguments["selected"] as string[];
            _useIndexTranslation = false;
            _onlineTranslation = null;
            await StartMachineLanguageAsync();
        }
        catch (Exception error) { ShowStatus("本机补译失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private bool _useIndexTranslation;

    private async void IndexLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (_languageBusy || _languageTranslationTask is { IsCompleted: false }) return;
        if (_launchTask is { IsCompleted: false })
        {
            ShowStatus("游戏正在运行。退出后即可开始本机补译。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            var arguments = SelectedLanguageArguments();
            var dialog = new ContentDialog
            {
                XamlRoot = RootShell.XamlRoot,
                Title = "使用进阶本机翻译",
                Content = "此功能使用 Index-Translate 2B Q4_K_M。首次需要通过 WinGet 安装 llama.cpp，并下载约 1.31 GB 的模型；建议预留至少 1.5 GB 磁盘空间。模型只在本机运行，使用较低进程优先级和两个 CPU 线程。翻译仅在 Minecraft 退出时执行，开始游戏会暂停并在退出后续跑。",
                PrimaryButtonText = "准备并开始",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || _launchTask is { IsCompleted: false } || _languageBusy) return;
            _pausedTranslationScope = arguments["selected"] as string[];
            _useIndexTranslation = true;
            _onlineTranslation = null;
            await StartMachineLanguageAsync();
        }
        catch (Exception error) { ShowStatus("进阶本机补译失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private OnlineTranslationClient? _onlineTranslation;

    private async void OnlineLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (_languageBusy || _languageTranslationTask is { IsCompleted: false } || _launchTask is { IsCompleted: false })
        {
            ShowStatus("请等待当前游戏或补译任务结束。", InfoBarSeverity.Warning);
            return;
        }
        try
        {
            var arguments = SelectedLanguageArguments();
            var engine = new ComboBox
            {
                Header = "翻译服务", ItemsSource = new[] { "B 站 Index-Translate", "阿里云 Qwen-MT", "MyMemory", "Google 公共接口" },
                SelectedIndex = 0, MinWidth = 280
            };
            var key = new PasswordBox { Header = "阿里云 API 密钥", MaxLength = 512, Visibility = Visibility.Collapsed };
            var notice = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 360 };
            void SelectEngine()
            {
                var selected = (OnlineTranslator)Math.Max(0, engine.SelectedIndex);
                key.Visibility = selected == OnlineTranslator.Qwen ? Visibility.Visible : Visibility.Collapsed;
                notice.Text = $"未译文字会发送给 {OnlineTranslationClient.OriginName(selected)}。每次最多处理 64 条。";
            }
            engine.SelectionChanged += (_, _) => SelectEngine();
            SelectEngine();
            var dialog = FriendDialog("在线补译", new StackPanel { Spacing = 8, Children = { engine, key, notice } }, "同意发送并补译");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || _languageBusy || _launchTask is { IsCompleted: false }) return;
            var provider = (OnlineTranslator)engine.SelectedIndex;
            string? token = null;
            if (provider == OnlineTranslator.Qwen)
            {
                var input = key.Password.Trim();
                key.Password = "";
                token = input.Length > 0 ? input : AppSecrets.Read("online-translation-qwen");
                if (string.IsNullOrEmpty(token) || token.Any(ch => char.IsWhiteSpace(ch) || char.IsControl(ch)))
                    throw new IOException("请输入有效的阿里云 API 密钥。");
                if (input.Length > 0) AppSecrets.Save("online-translation-qwen", input);
            }
            _pausedTranslationScope = arguments["selected"] as string[];
            _useIndexTranslation = false;
            _onlineTranslation = new OnlineTranslationClient(provider, token);
            await StartMachineLanguageAsync();
        }
        catch (Exception error) { ShowStatus("在线补译失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private Task StartMachineLanguageAsync()
    {
        if (_pausedTranslationScope is not { Length: > 0 } scope || _languageProject is null)
            return Task.CompletedTask;
        var request = ProjectLanguageArguments();
        request["selected"] = scope;
        _languageTranslationTask = RunMachineLanguageAsync(request, _onlineTranslation);
        return _languageTranslationTask;
    }

    private async Task RunMachineLanguageAsync(Dictionary<string, object?> request, OnlineTranslationClient? online)
    {
        using var cancellation = new CancellationTokenSource();
        _languageTranslation = cancellation;
        LanguageCancelButton.Visibility = Visibility.Visible;
        try
        {
            await LanguageOperationAsync(async () =>
            {
                try
                {
                    await TranslatePendingLanguageAsync(request, online, cancellation.Token);
                }
                catch (OperationCanceledException)
                {
                    if (_resumeAfterGame)
                        LanguageSummary.Text = "补译已暂停，Minecraft 退出后继续。";
                    else
                        ShowStatus("已停止补译，完成的译文已保存。", InfoBarSeverity.Informational);
                }
            });
        }
        finally
        {
            LanguageCancelButton.Visibility = Visibility.Collapsed;
            _languageTranslation = null;
        }
    }

    private async Task TranslatePendingLanguageAsync(Dictionary<string, object?> request, OnlineTranslationClient? online,
        CancellationToken cancellation)
    {
        var bridge = RequireBridge();
        var skipped = new HashSet<string>(StringComparer.Ordinal);
        var saved = 0;
        var attempted = 0;
        var project = (string)request["project"]!;
        request["limit"] = online is not null ? 4 : _useIndexTranslation ? 2 : 16;
        var pending = await bridge.InvokeAsync("langPending", request, cancellationToken: cancellation);
        if (pending["entries"] is not JsonArray { Count: > 0 })
        {
            ShowStatus("这个范围内没有待翻译的文字。", InfoBarSeverity.Informational);
            return;
        }

        var name = online is not null ? "在线" : _useIndexTranslation ? "Index-Translate 2B 本机" : "本机";
        ShowStatus($"正在启动{name}补译…", InfoBarSeverity.Informational);
        await using (IMachineTranslationWorker? worker = online is not null ? null : _useIndexTranslation
            ? await IndexTranslationWorker.StartAsync(message => ShowStatus(message, InfoBarSeverity.Informational), cancellation)
            : await LocalTranslationWorker.StartAsync(message => ShowStatus(message, InfoBarSeverity.Informational), cancellation))
        {
            while (pending["entries"] is JsonArray { Count: > 0 } rows)
            {
                var work = rows.OfType<JsonObject>().ToArray();
                var texts = work.Select(row => row["source"]!.GetValue<string>()).ToArray();
                var translations = online is null
                    ? await worker!.TranslateAsync(texts, cancellation)
                    : await online.TranslateAsync(texts, cancellation);
                var changes = new List<Dictionary<string, string>>(work.Length);
                var batchKeys = new HashSet<string>(StringComparer.Ordinal);
                for (var index = 0; index < work.Length; index++)
                {
                    var resource = work[index]["resource"]!.GetValue<string>();
                    var id = work[index]["id"]!.GetValue<string>();
                    if (!string.IsNullOrWhiteSpace(translations[index]))
                    {
                        batchKeys.Add($"{resource}/{id}");
                        changes.Add(new Dictionary<string, string>
                        {
                            ["resource"] = resource, ["entry"] = id,
                            ["source"] = work[index]["source"]!.GetValue<string>(),
                            ["translation"] = translations[index]!
                        });
                    }
                    else
                        skipped.Add($"{resource}/{id}");
                }
                if (changes.Count > 0)
                {
                    // Save a completed batch even when a game launch has just requested a pause.
                    var result = await bridge.InvokeAsync("langSave", new Dictionary<string, object?>
                    {
                        ["project"] = project, ["changes"] = changes, ["onlyMissing"] = true, ["origin"] = online is null ? "machine" : "online"
                    });
                    saved += result["saved"]?.GetValue<int>() ?? 0;
                    if (result["skipped"]?.GetValue<int>() > 0) skipped.UnionWith(batchKeys);
                    if (result["project"] is JsonObject updated) SetLanguageProject(updated);
                }
                attempted += work.Length;
                LanguageSummary.Text = $"{name}补译已保存 {saved} 条译文，已处理 {attempted} 条。";
                cancellation.ThrowIfCancellationRequested();
                // Java bounds each response. Group only unsupported rows into the skip list in later requests.
                request["skip"] = skipped.Take(16384).ToArray();
                if (skipped.Count >= 16384)
                    break;
                if (online is not null && attempted >= 64) break;
                pending = await bridge.InvokeAsync("langPending", request, cancellationToken: cancellation);
            }
        }
        await ReadLanguagePageAsync(_languageOffset);
        ShowStatus($"{name}补译已保存 {saved} 条，{attempted - saved} 条留待校对。", InfoBarSeverity.Success);
    }

    private void CancelLanguageTranslation_Click(object sender, RoutedEventArgs e)
    {
        _resumeAfterGame = false;
        _languageTranslation?.Cancel();
    }

    private async Task PauseLanguageForGameAsync()
    {
        if (_languageTranslationTask is not { IsCompleted: false } active) return;
        _resumeAfterGame = _onlineTranslation is null;
        _languageTranslation?.Cancel();
        await active;
    }

    private void ResumeLanguageAfterGame()
    {
        if (!_resumeAfterGame || _closing) return;
        _resumeAfterGame = false;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_languageBusy || _launchTask is { IsCompleted: false }) return;
            _ = StartMachineLanguageAsync();
        });
    }
}
