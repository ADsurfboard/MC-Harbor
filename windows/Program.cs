using System.Security.Cryptography;
using System.Text;
using System.Threading;
using MCHarbor.Windows.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace MCHarbor.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            if (WindowsPlatform.ClientArchitecture == "arm64" && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100))
            {
                ShowLaunchError(IntPtr.Zero, "ARM64 版本需要 Windows 11 24H2 或更新版本。", "MC Harbor ARM64", 0x10);
                return;
            }
            WinRT.ComWrappersSupport.InitializeComWrappers();
            var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppPaths.DataDirectory.ToUpperInvariant())));
            var current = AppInstance.FindOrRegisterForKey("MC-Harbor-" + identity);
            var inbox = new ShortcutActivationInbox(Path.Combine(AppPaths.DataDirectory, "shortcut-inbox"));
            if (!current.IsCurrent)
            {
                using var pending = inbox.Create(App.ParseInstance(args));
                var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
                var redirect = Task.Run(async () => await current.RedirectActivationToAsync(activation));
                _ = redirect.ContinueWith(task => { _ = task.Exception; },
                    TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
                if (!pending.WaitForReceiptAsync(TimeSpan.FromSeconds(60)).GetAwaiter().GetResult())
                    throw new TimeoutException("启动器尚未接收快捷启动请求，请打开 MC Harbor 后重试。");
                return;
            }
            var activationLock = new object();
            var pendingActivations = 0;
            App? app = null;
            current.Activated += (_, _) =>
            {
                lock (activationLock)
                {
                    if (app is not null) app.RedirectActivation();
                    else pendingActivations++;
                }
            };
            Application.Start(_ =>
            {
                var dispatcher = DispatcherQueue.GetForCurrentThread();
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(dispatcher));
                lock (activationLock)
                {
                    app = new App(args, dispatcher, inbox);
                    if (pendingActivations > 0) app.RedirectActivation();
                }
            });
        }
        catch (Exception error)
        {
            var path = StartupDiagnostics.Write("启动失败", error);
            ShowLaunchError(IntPtr.Zero, path is null ? "MC Harbor 无法启动。" : $"MC Harbor 无法启动。\n错误记录：{path}",
                "MC Harbor", 0x10);
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "MessageBoxW",
        CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int ShowLaunchError(IntPtr window, string message, string title, uint type);
}
