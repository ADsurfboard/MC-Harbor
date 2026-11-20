using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MCHarbor.Windows.Services;

internal sealed class BridgeClient
{
    private readonly string _javaExecutable;

    public BridgeClient(string javaExecutable) => _javaExecutable = javaExecutable;

    public async Task<JsonObject> InvokeAsync(
        string command,
        IReadOnlyDictionary<string, object?>? arguments = null,
        Action<JsonObject>? onEvent = null,
        CancellationToken cancellationToken = default)
    {
        EnsureRuntimeFiles();
        var java = _javaExecutable;
        var moduleFx = WindowsPlatform.UsesJavaFxModules;
        if (moduleFx && UsesGameCompatibility(command))
        {
            java = Path.Combine(AppPaths.ApplicationDirectory, "Compatibility", "JavaX64", "bin", "java.exe");
            if (!File.Exists(java)) throw new BridgeException("缺少游戏兼容运行时，请解压完整 ARM64 发行包。");
            moduleFx = false;
        }
        var classpath = new List<string> { AppPaths.BackendJar, AppPaths.HmclJar };
        if (!moduleFx) classpath.Add(Path.Combine(AppPaths.JavaFxDirectory, "*"));
        var startInfo = new ProcessStartInfo
        {
            FileName = java,
            WorkingDirectory = AppPaths.ApplicationDirectory,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        if (moduleFx)
        {
            startInfo.ArgumentList.Add("--add-modules");
            startInfo.ArgumentList.Add("javafx.controls");
        }
        foreach (var argument in new[]
        {
            "-Xms32m", "-Xmx384m", "-Dfile.encoding=UTF-8", "-Djava.awt.headless=true",
            "-Dshenggan.headless=true", $"-Dhmcl.dir={AppPaths.DataDirectory}", "-cp",
            string.Join(Path.PathSeparator, classpath),
            "net.morben.shenggan.NativeBridge"
        }) startInfo.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start()) throw new BridgeException("Java 后端没有启动。");
        }
        catch (Win32Exception error)
        {
            throw new BridgeException("无法启动 Java。请安装随应用提供的 Java 21 运行时，或在设置中选择 Java。", error);
        }

        var stderrDrain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, CancellationToken.None);
        var request = new JsonObject
        {
            ["command"] = command,
            ["root"] = AppPaths.GameRoot,
            ["source"] = AppPaths.GetPreference("downloadSource", "auto"),
            ["threads"] = 8
        };
        if (arguments is not null)
        {
            foreach (var (key, value) in arguments)
                request[key] = value is JsonNode node ? node.DeepClone() : JsonSerializer.SerializeToNode(value);
        }

        JsonObject? result = null;
        string? backendError = null;
        try
        {
            await process.StandardInput.WriteLineAsync(request.ToJsonString());
            process.StandardInput.Close();

            while (await process.StandardOutput.ReadLineAsync(cancellationToken) is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                JsonObject message;
                try
                {
                    message = JsonNode.Parse(line)?.AsObject() ?? throw new JsonException("不是 JSON 对象");
                }
                catch (JsonException)
                {
                    continue;
                }

                var kind = message["event"]?.GetValue<string>();
                if (kind == "result") result = message["data"]?.AsObject().DeepClone().AsObject();
                else if (kind == "error") backendError = message["message"]?.GetValue<string>();
                try { onEvent?.Invoke(message); }
                catch { /* UI event handlers must not break the bridge pipe. */ }
            }

            await process.WaitForExitAsync(cancellationToken);
            await stderrDrain;
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }

        if (backendError is not null) throw new BridgeException(backendError);
        if (process.ExitCode != 0) throw new BridgeException($"Java 后端退出，代码 {process.ExitCode}。");
        return result ?? throw new BridgeException("Java 后端未返回结果。");
    }

    internal static bool UsesGameCompatibility(string command) => command is
        "launch" or "install" or "repair" or "runtime" or "inspectJava" or "import";

    private static void EnsureRuntimeFiles()
    {
        if (!File.Exists(AppPaths.BackendJar)) throw new BridgeException("缺少 Backend.jar。请先按 Windows 构建说明编译后端。");
        if (!File.Exists(AppPaths.HmclJar)) throw new BridgeException("缺少 HMCLCore.jar。请保留随 MC Harbor 分发的内核文件。");
        if (WindowsPlatform.UsesJavaFxModules)
        {
            if (!File.Exists(Path.Combine(AppPaths.ApplicationDirectory, "Runtime", "lib", "modules")))
                throw new BridgeException("缺少 ARM64 JavaFX 模块运行时，请解压完整发行包。");
            return;
        }
        if (!Directory.Exists(AppPaths.JavaFxDirectory)
            || !Directory.EnumerateFiles(AppPaths.JavaFxDirectory, "*.jar").Any())
            throw new BridgeException("缺少 Windows JavaFX 依赖。请先准备随应用分发的 JavaFX 文件。");
    }
}

internal sealed class BridgeException : Exception
{
    public BridgeException(string message) : base(message) { }
    public BridgeException(string message, Exception innerException) : base(message, innerException) { }
}
