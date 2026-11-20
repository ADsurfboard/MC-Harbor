using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Dispatching;
using MCHarbor.Windows.Services;

namespace MCHarbor.Windows;

public partial class App : Application
{
    private Window? _window;
    private readonly DispatcherQueue _dispatcher;
    private readonly Queue<string?> _pending = new();
    private readonly ShortcutActivationInbox _shortcutInbox;
    private readonly DispatcherQueueTimer _shortcutTimer;

    internal App(string[] arguments, DispatcherQueue dispatcher, ShortcutActivationInbox inbox)
    {
        _dispatcher = dispatcher;
        _shortcutInbox = inbox;
        _shortcutTimer = dispatcher.CreateTimer();
        _shortcutTimer.Interval = TimeSpan.FromMilliseconds(200);
        _shortcutTimer.Tick += (_, _) => ConsumeShortcutRequests();
        _pending.Enqueue(ParseInstance(arguments));
        UnhandledException += (_, args) => StartupDiagnostics.Write("界面运行错误", args.Exception);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            var main = new MainWindow();
            _window = main;
            while (_pending.TryDequeue(out var id)) main.QueueActivation(id);
        }
        catch (Exception error)
        {
            var log = StartupDiagnostics.Write("主窗口初始化失败", error);
            _window = new Window
            {
                Title = "MC Harbor",
                Content = new TextBlock
                {
                    Text = "MC Harbor 无法载入主界面。"
                        + (log is null ? "" : $"\n错误记录：{log}"),
                    Margin = new Thickness(24),
                    TextWrapping = TextWrapping.Wrap
                }
            };
        }
        _window.Closed += (_, _) => { _shortcutTimer.Stop(); Exit(); };
        _window.Activate();
        _shortcutTimer.Start();
        ConsumeShortcutRequests();
    }

    internal void RedirectActivation() => _dispatcher.TryEnqueue(() =>
    {
        ConsumeShortcutRequests();
        ActivateInstance(null);
    });

    private void ConsumeShortcutRequests()
    {
        try { _shortcutInbox.Consume(ActivateInstance); }
        catch (Exception error) { StartupDiagnostics.Write("快捷启动交接失败", error); }
    }

    private void ActivateInstance(string? id)
    {
        if (_window is MainWindow main)
        {
            if (main.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter
                && presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized)
                presenter.Restore();
            main.Activate();
            main.QueueActivation(id);
        }
        else _pending.Enqueue(id);
    }

    internal static string? ParseInstance(string[] args)
    {
        var index = Array.IndexOf(args, "--launch");
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

}
