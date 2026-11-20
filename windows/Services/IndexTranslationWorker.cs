using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MCHarbor.Windows.Services;

internal sealed partial class IndexTranslationWorker : IMachineTranslationWorker
{
    private const string ModelFileName = "Index-Translate-2B.Q4_K_M.gguf";
    private const string ModelRevision = "0a622669d15a139787818187e6263d19e4a1ffb5";
    private const string ModelSha256 = "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a";
    private const long ModelSize = 1_312_164_352;
    private const string ModelAlias = "Index-Translate-2B";
    private static readonly HttpClient DownloadClient = new() { Timeout = Timeout.InfiniteTimeSpan };

    private readonly Process _server;
    private readonly HttpClient _client;
    private readonly ConcurrentQueue<string> _log = new();

    private IndexTranslationWorker(Process server, HttpClient client)
    {
        _server = server;
        _client = client;
        _server.OutputDataReceived += (_, args) => KeepLog(args.Data);
        _server.ErrorDataReceived += (_, args) => KeepLog(args.Data);
        _server.BeginOutputReadLine();
        _server.BeginErrorReadLine();
        try { _server.PriorityClass = ProcessPriorityClass.BelowNormal; }
        catch (System.ComponentModel.Win32Exception) { }
        catch (InvalidOperationException) { }
    }

    public static async Task<IndexTranslationWorker> StartAsync(Action<string> progress, CancellationToken cancellation)
    {
        var executable = ResolveLlamaExecutable();
        if (executable is null)
        {
            progress("正在通过 WinGet 安装 llama.cpp…");
            await InstallLlamaAsync(cancellation);
            executable = ResolveLlamaExecutable();
            if (executable is null)
                throw new IOException("llama.cpp 已安装，但当前 Windows 会话尚未找到 llama.exe。请关闭并重新打开 MC Harbor 后重试。");
        }

        var model = await EnsureModelAsync(progress, cancellation);
        cancellation.ThrowIfCancellationRequested();
        progress("正在加载 Index-Translate 2B 本机模型…");
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();

        var settings = new ProcessStartInfo(executable)
        {
            WorkingDirectory = Path.GetDirectoryName(executable)!,
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        if (Path.GetFileNameWithoutExtension(executable).Equals("llama", StringComparison.OrdinalIgnoreCase))
            settings.ArgumentList.Add("serve");
        foreach (var argument in new[]
        {
            "-m", model, "--host", "127.0.0.1", "--port", port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--alias", ModelAlias, "--ctx-size", "4096", "--threads", "2", "--threads-batch", "2",
            "--parallel", "1", "--jinja", "--chat-template-kwargs", "{\"enable_thinking\":false}",
            "--temp", "0", "--device", "none", "--poll", "0", "--poll-batch", "0", "--no-webui"
        }) settings.ArgumentList.Add(argument);

        var process = Process.Start(settings) ?? throw new IOException("无法启动 llama.cpp 本机翻译服务。");
        var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/"), Timeout = Timeout.InfiniteTimeSpan };
        var worker = new IndexTranslationWorker(process, client);
        try
        {
            var deadline = DateTime.UtcNow.AddMinutes(15);
            while (DateTime.UtcNow < deadline)
            {
                cancellation.ThrowIfCancellationRequested();
                if (process.HasExited)
                    throw new IOException("llama.cpp 无法加载本机模型。" + worker.LogTail());
                try
                {
                    using var healthTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                    healthTimeout.CancelAfter(TimeSpan.FromSeconds(3));
                    using var response = await client.GetAsync("health", HttpCompletionOption.ResponseHeadersRead, healthTimeout.Token);
                    if (response.IsSuccessStatusCode) return worker;
                }
                catch (HttpRequestException) { }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { }
                progress("正在加载 Index-Translate 2B 本机模型…");
                await Task.Delay(800, cancellation);
            }
            throw new TimeoutException("Index-Translate 2B 模型加载超时。" + worker.LogTail());
        }
        catch
        {
            await worker.DisposeAsync();
            throw;
        }
    }

    public async Task<string?[]> TranslateAsync(string[] texts, CancellationToken cancellation)
    {
        var output = new string?[texts.Length];
        for (var index = 0; index < texts.Length; index++)
        {
            cancellation.ThrowIfCancellationRequested();
            if (texts[index].Length is 0 or > 8192) continue;
            output[index] = await TranslateOneAsync(texts[index], cancellation);
        }
        return output;
    }

    private async Task<string?> TranslateOneAsync(string text, CancellationToken cancellation)
    {
        var segments = ProtectedPattern().Split(text);
        var result = new StringBuilder(text.Length + 24);
        for (var index = 0; index < segments.Length; index++)
        {
            var segment = segments[index];
            if (index % 2 == 1 || !EnglishPattern().IsMatch(segment))
            {
                result.Append(segment);
                continue;
            }

            foreach (var piece in SplitLongText(segment, 1800))
            {
                var leading = piece[..(piece.Length - piece.TrimStart().Length)];
                var trailing = piece[piece.TrimEnd().Length..];
                var source = piece.Trim();
                if (source.Length == 0 || !EnglishPattern().IsMatch(source))
                {
                    result.Append(piece);
                    continue;
                }
                var translated = await RequestAsync(source, cancellation);
                if (translated is null) return null;
                result.Append(leading).Append(translated).Append(trailing);
            }
        }
        var value = result.ToString();
        return ChinesePattern().IsMatch(value) && !value.Equals(text, StringComparison.OrdinalIgnoreCase) ? value : null;
    }

    private async Task<string?> RequestAsync(string source, CancellationToken cancellation)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            model = ModelAlias,
            messages = new[]
            {
                new { role = "system", content = "你是 Minecraft 本地化翻译器。只把源文翻译成简体中文；原样保留占位符、代码格式和专有标识，不要解释。" },
                new { role = "user", content = "请将以下文本翻译为简体中文，直接输出翻译结果，不要进行任何解释。\n\n〖源文〗" + source }
            },
            temperature = 0,
            max_tokens = 2048,
            stream = false
        });
        using var request = new HttpRequestMessage(HttpMethod.Post, "v1/chat/completions")
        {
            Content = new ByteArrayContent(body)
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        requestTimeout.CancelAfter(TimeSpan.FromMinutes(5));
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, requestTimeout.Token);
        if (!response.IsSuccessStatusCode)
            throw new IOException("本机 2B 翻译服务返回错误：" + (int)response.StatusCode + "." + LogTail());
        var payload = await response.Content.ReadAsByteArrayAsync(requestTimeout.Token);
        var root = JsonNode.Parse(payload);
        if (root?["choices"] is not JsonArray { Count: > 0 } choices || choices[0] is not JsonObject choice
            || choice["finish_reason"]?.GetValue<string>() != "stop")
            return null;
        var value = choice["message"]?["content"]?.GetValue<string>()?.Trim();
        return !string.IsNullOrWhiteSpace(value) && ChinesePattern().IsMatch(value) ? value : null;
    }

    private static async Task<string> EnsureModelAsync(Action<string> progress, CancellationToken cancellation)
    {
        var directory = Path.Combine(LocalTranslationWorker.StateDirectory, "index-translate-2b-q4km-v1");
        var model = Path.Combine(directory, ModelFileName);
        Directory.CreateDirectory(directory);
        if (File.Exists(model) && new FileInfo(model).Length == ModelSize)
        {
            progress("正在校验本机 2B 模型…");
            await using var existing = new FileStream(model, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, true);
            var actual = Convert.ToHexString(await SHA256.HashDataAsync(existing, cancellation));
            if (actual.Equals(ModelSha256, StringComparison.OrdinalIgnoreCase)) return model;
            File.Delete(model);
        }
        else if (File.Exists(model)) File.Delete(model);

        var drive = new DriveInfo(Path.GetPathRoot(directory)!);
        if (drive.IsReady && drive.AvailableFreeSpace < ModelSize + 128L * 1024 * 1024)
            throw new IOException("磁盘空间不足。下载并校验进阶模型至少需要 1.5 GB 可用空间。");

        var partial = model + ".partial";
        var offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (offset >= ModelSize)
        {
            File.Delete(partial);
            offset = 0;
        }
        var url = $"https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/{ModelRevision}/{ModelFileName}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("MC-Harbor-Windows/1.0");
        if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
        using var response = await DownloadClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        var resume = offset > 0 && response.StatusCode == HttpStatusCode.PartialContent
            && response.Content.Headers.ContentRange?.From == offset;
        if (response.StatusCode == HttpStatusCode.PartialContent && !resume)
            throw new IOException("模型下载服务器返回了不匹配的续传范围，请重试。");
        if (!resume) offset = 0;
        await using (var output = new FileStream(partial, resume ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024, true))
        await using (var input = await response.Content.ReadAsStreamAsync(cancellation))
        {
            var buffer = new byte[1024 * 1024];
            var total = offset;
            var nextReport = offset;
            int count;
            while ((count = await input.ReadAsync(buffer, cancellation)) > 0)
            {
                total += count;
                if (total > ModelSize) throw new IOException("下载的 2B 模型大小超出官方清单。");
                await output.WriteAsync(buffer.AsMemory(0, count), cancellation);
                if (total >= nextReport)
                {
                    progress($"下载 Index-Translate 2B… {100L * total / ModelSize}%（{total / (1024 * 1024)} MB）");
                    nextReport = total + 32L * 1024 * 1024;
                }
            }
            await output.FlushAsync(cancellation);
            if (total != ModelSize) throw new IOException("2B 模型下载未完成。再次点击可续传尚未下载的部分。");
        }

        progress("正在校验 Index-Translate 2B 模型…");
        await using (var stream = new FileStream(partial, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, true))
        {
            var actual = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellation));
            if (!actual.Equals(ModelSha256, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(partial);
                throw new IOException("2B 模型校验失败，已移除损坏文件。请重试下载。");
            }
        }
        File.Move(partial, model, overwrite: true);
        return model;
    }

    private static async Task InstallLlamaAsync(CancellationToken cancellation)
    {
        var winget = FindExecutable("winget.exe");
        if (winget is null) throw new IOException("没有找到 WinGet。请先安装 llama.cpp，或更新 Windows 应用安装程序后重试。安装命令：winget install llama.cpp");
        var settings = new ProcessStartInfo(winget)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in new[] { "install", "--id", "ggml.llamacpp", "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements", "--silent", "--disable-interactivity" })
            settings.ArgumentList.Add(argument);
        using var installer = Process.Start(settings) ?? throw new IOException("无法启动 WinGet 安装程序。");
        var stdout = installer.StandardOutput.ReadToEndAsync(cancellation);
        var stderr = installer.StandardError.ReadToEndAsync(cancellation);
        try { await installer.WaitForExitAsync(cancellation); }
        catch (OperationCanceledException)
        {
            try { installer.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }
        var details = ((await stderr) + " " + (await stdout)).Trim();
        if (installer.ExitCode != 0)
            throw new IOException("llama.cpp 安装失败。" + (details.Length > 240 ? details[^240..] : details));
    }

    private static string? ResolveLlamaExecutable() => FindExecutable("llama.exe")
        ?? FindExecutable("llama-server.exe");

    private static string? FindExecutable(string name)
    {
        var candidates = new List<string>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        candidates.Add(Path.Combine(local, "Microsoft", "WinGet", "Links", name));
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(directory.Trim().Trim('"'), name));
        return candidates.FirstOrDefault(path => File.Exists(path));
    }

    private static IEnumerable<string> SplitLongText(string text, int maximum)
    {
        var offset = 0;
        while (offset < text.Length)
        {
            var end = Math.Min(text.Length, offset + maximum);
            if (end < text.Length)
            {
                var boundary = text.LastIndexOfAny([' ', '\t', '\r', '\n'], end - 1, end - offset);
                if (boundary > offset + maximum / 3) end = boundary + 1;
            }
            yield return text[offset..end];
            offset = end;
        }
    }

    private void KeepLog(string? line)
    {
        if (line is null) return;
        _log.Enqueue(line);
        while (_log.Count > 20) _log.TryDequeue(out _);
    }

    private string LogTail()
    {
        var lines = _log.ToArray().Where(line => !string.IsNullOrWhiteSpace(line)).TakeLast(5);
        var tail = string.Join(" | ", lines);
        return tail.Length == 0 ? "" : " 日志：" + (tail.Length > 700 ? tail[^700..] : tail);
    }

    [GeneratedRegex(@"%(?:\d+\$)?[-+#0,(<]*\d*(?:\.\d+)?[tT]?[A-Za-z%]|\$\{[^{}]+\}|\$\([^()]+\)|\{[^{}\r\n]+\}|[&§](?:#[0-9a-fA-F]{6}|[0-9A-FK-ORZa-fk-orz])|https?://[^\s<>]+|\b[a-z0-9_.-]+:[a-z0-9_./-]+\b|\[\[[^\]\r\n]+\]\]|\r\n|\r|\n")]
    private static partial Regex ProtectedPattern();
    [GeneratedRegex("[A-Za-z]")]
    private static partial Regex EnglishPattern();
    [GeneratedRegex("[\u3400-\u9fff]")]
    private static partial Regex ChinesePattern();

    public async ValueTask DisposeAsync()
    {
        _client.Dispose();
        try
        {
            if (!_server.HasExited) _server.Kill(entireProcessTree: true);
            await _server.WaitForExitAsync();
        }
        catch (InvalidOperationException) { }
        finally { _server.Dispose(); }
    }
}
