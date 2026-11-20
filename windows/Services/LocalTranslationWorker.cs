using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal interface IMachineTranslationWorker : IAsyncDisposable
{
    Task<string?[]> TranslateAsync(string[] texts, CancellationToken cancellation);
}

internal sealed class LocalTranslationWorker : IMachineTranslationWorker
{
    private readonly Process _process;
    private readonly Task _stderr;

    private LocalTranslationWorker(Process process)
    {
        _process = process;
        _stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
        try { process.PriorityClass = ProcessPriorityClass.BelowNormal; }
        catch (System.ComponentModel.Win32Exception) { }
        catch (InvalidOperationException) { }
    }

    public static string StateDirectory => Path.Combine(AppPaths.DataDirectory, "translation");
    public static bool ModelIsReady => File.Exists(Path.Combine(StateDirectory, "opus-en-zh-2020-07-17-ct2-int8-v1", "model.bin"));

    public static async Task<LocalTranslationWorker> StartAsync(Action<string> progress, CancellationToken cancellation)
    {
        var folder = Path.Combine(AppPaths.ApplicationDirectory, "Translation");
        var python = Path.Combine(folder, "Python", "python.exe");
        if (!File.Exists(python)) throw new IOException("此发布目录缺少本机翻译运行环境。请解压完整的 Windows 发行包。");
        var settings = new ProcessStartInfo(python)
        {
            WorkingDirectory = folder,
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false)
        };
        foreach (var argument in new[] { "-IB", Path.Combine(folder, "worker.py"), "--state-dir", StateDirectory })
            settings.ArgumentList.Add(argument);
        var process = Process.Start(settings) ?? throw new IOException("无法启动本机翻译进程。");
        var worker = new LocalTranslationWorker(process);
        try
        {
            while (true)
            {
                var message = await worker.ReadAsync(cancellation);
                if (message["event"]?.GetValue<string>() == "ready") return worker;
                if (message["message"]?.GetValue<string>() is { } stage) progress(stage);
            }
        }
        catch
        {
            await worker.DisposeAsync();
            throw;
        }
    }

    public async Task<string?[]> TranslateAsync(string[] texts, CancellationToken cancellation)
    {
        var request = JsonSerializer.Serialize(new { texts });
        await _process.StandardInput.WriteLineAsync(request.AsMemory(), cancellation);
        await _process.StandardInput.FlushAsync(cancellation);
        var response = await ReadAsync(cancellation);
        var result = (response["translations"] as JsonArray)?.Select(item => item?.GetValue<string>()).ToArray();
        return result is not null && result.Length == texts.Length
            ? result : throw new IOException("本机翻译返回了无效批次。");
    }

    private async Task<JsonObject> ReadAsync(CancellationToken cancellation)
    {
        var line = await _process.StandardOutput.ReadLineAsync(cancellation)
            ?? throw new IOException("本机翻译进程已退出，请检查运行环境后重试。");
        var response = JsonNode.Parse(line)?.AsObject() ?? throw new IOException("无法读取本机翻译响应。");
        if (response["event"]?.GetValue<string>() == "error")
            throw new IOException(response["message"]?.GetValue<string>() ?? "本机翻译失败。");
        return response;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
            await _process.WaitForExitAsync();
            await _stderr;
        }
        catch (InvalidOperationException) { }
        finally { _process.Dispose(); }
    }
}
