using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text.Json;
using MCHarbor.Windows.Services;

// The same test host acts as a disposable Java stand-in for real pipe/routing checks.
if (args.Contains("-cp"))
{
    var request = await Console.In.ReadLineAsync();
    using var json = JsonDocument.Parse(request!);
    var cp = args[Array.IndexOf(args, "-cp") + 1];
    Console.WriteLine(JsonSerializer.Serialize(new { @event = "result", data = new
    {
        command = json.RootElement.GetProperty("command").GetString(),
        modules = args.Contains("--add-modules"), externalFx = cp.Contains("javafx" + Path.DirectorySeparatorChar),
        compatibility = Environment.ProcessPath!.Contains(Path.Combine("Compatibility", "JavaX64"))
    }}));
    return;
}

var checks = 0;
void Check(bool value, string label)
{
    if (!value) throw new InvalidOperationException("FAIL: " + label);
    checks++;
    Console.WriteLine("PASS: " + label);
}
Check(WindowsPlatform.ArchitectureName(Architecture.Arm64) == "arm64", "ARM64 architecture label");
Check(WindowsPlatform.ArchitectureName(Architecture.X64) == "x64", "x64 architecture label");
if (args.Length == 2 && args[0] == "--expect-architecture")
    Check(WindowsPlatform.ClientArchitecture == args[1], "Tests execute in the requested native architecture");
byte[] Pe(ushort machine)
{
    var bytes = new byte[128];
    bytes[0] = (byte)'M'; bytes[1] = (byte)'Z';
    BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(0x3c), 64);
    BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), 0x4550);
    BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(68), machine);
    return bytes;
}
Check(WindowsPlatform.MatchesMachine(Pe(0xAA64), WindowsPlatform.MachineFor("arm64")), "ARM64 PE accepted");
Check(!WindowsPlatform.MatchesMachine(Pe(0x8664), WindowsPlatform.MachineFor("arm64")), "x64 PE rejected for ARM64");
Check(!WindowsPlatform.MatchesMachine(new byte[128], 0xAA64), "Malformed PE rejected");
var invalid = Pe(0xAA64);
BinaryPrimitives.WriteInt32LittleEndian(invalid.AsSpan(0x3c), int.MaxValue);
Check(!WindowsPlatform.MatchesMachine(invalid, 0xAA64), "Out-of-range PE pointer rejected");
foreach (var command in new[] { "launch", "install", "repair", "runtime", "inspectJava", "import" })
    Check(BridgeClient.UsesGameCompatibility(command), "Compatibility routing: " + command);
foreach (var command in new[] { "login", "migrate", "resources", "langRead", "worldSave" })
    Check(!BridgeClient.UsesGameCompatibility(command), "Native routing: " + command);

var temporary = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "harbor-platform-check-" + Guid.NewGuid().ToString("N")));
Directory.CreateDirectory(temporary);
try
{
    AppPaths.Root = temporary;
    Directory.CreateDirectory(AppPaths.BackendDirectory);
    Directory.CreateDirectory(AppPaths.JavaFxDirectory);
    Directory.CreateDirectory(Path.Combine(temporary, "Runtime", "lib"));
    File.WriteAllText(AppPaths.BackendJar, "synthetic");
    File.WriteAllText(AppPaths.HmclJar, "synthetic");
    File.WriteAllText(Path.Combine(AppPaths.JavaFxDirectory, "synthetic.jar"), "synthetic");
    File.WriteAllText(Path.Combine(temporary, "Runtime", "lib", "modules"), "synthetic");
    File.WriteAllText(Path.Combine(AppPaths.BackendDirectory, "runtime.json"), "{\"javaFxMode\":\"modules\"}");
    string CopyHost(string folder)
    {
        Directory.CreateDirectory(folder);
        var host = Environment.ProcessPath!;
        if (Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Run platform checks with dotnet run so the apphost is available.");
        var assembly = typeof(WindowsPlatform).Assembly.Location;
        File.Copy(host, Path.Combine(folder, "java.exe"));
        File.Copy(assembly, Path.Combine(folder, Path.GetFileName(assembly)));
        foreach (var suffix in new[] { ".runtimeconfig.json", ".deps.json" })
        {
            var file = Path.ChangeExtension(assembly, null) + suffix;
            File.Copy(file, Path.Combine(folder, Path.GetFileName(file)));
        }
        return Path.Combine(folder, "java.exe");
    }
    var nativeJava = CopyHost(Path.Combine(temporary, "Runtime", "bin"));
    Check(JavaRuntimeLocator.FindLauncherJava() == nativeJava, "Bundled native Java preferred");
    var bridge = new BridgeClient(nativeJava);
    var rejected = false;
    try { await bridge.InvokeAsync("launch"); } catch (BridgeException) { rejected = true; }
    Check(rejected, "Missing compatibility runtime fails before launch");
    CopyHost(Path.Combine(temporary, "Compatibility", "JavaX64", "bin"));
    var native = await bridge.InvokeAsync("resources");
    Check(native["modules"]!.GetValue<bool>() && !native["compatibility"]!.GetValue<bool>()
        && !native["externalFx"]!.GetValue<bool>(), "Native bridge uses modules without x64 JavaFX classpath");
    var game = await bridge.InvokeAsync("runtime");
    Check(!game["modules"]!.GetValue<bool>() && game["compatibility"]!.GetValue<bool>()
        && game["externalFx"]!.GetValue<bool>(), "Game bridge uses isolated compatibility executable and classpath");
}
finally
{
    var prefix = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    if (!temporary.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
        || !Path.GetFileName(temporary).StartsWith("harbor-platform-check-", StringComparison.Ordinal))
        throw new InvalidOperationException("Test cleanup escaped the disposable directory.");
    // Windows scanners can briefly retain a mapped executable after process exit.
    for (var attempt = 0; ; attempt++)
    {
        try { Directory.Delete(temporary, recursive: true); break; }
        catch (IOException) when (attempt < 19) { await Task.Delay(100); }
        catch (UnauthorizedAccessException) when (attempt < 19) { await Task.Delay(100); }
    }
}
Console.WriteLine($"{checks} platform checks passed.");

namespace MCHarbor.Windows.Services
{
    internal static class AppPaths
    {
        internal static string Root = "";
        internal static string ApplicationDirectory => Root;
        internal static string BackendDirectory => Path.Combine(Root, "Backend");
        internal static string BackendJar => Path.Combine(BackendDirectory, "Backend.jar");
        internal static string HmclJar => Path.Combine(BackendDirectory, "HMCLCore.jar");
        internal static string JavaFxDirectory => Path.Combine(BackendDirectory, "javafx");
        internal static string DataDirectory => Path.Combine(Root, "synthetic-data");
        internal static string GameRoot => Path.Combine(Root, "synthetic-game");
        internal static string GetPreference(string key, string fallback) => fallback;
    }
}
