using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal static class WindowsPlatform
{
    internal const ushort Amd64Machine = 0x8664;
    internal const ushort Arm64Machine = 0xAA64;
    internal static string NativeArchitecture => ArchitectureName(RuntimeInformation.OSArchitecture);
    internal static string ClientArchitecture => ArchitectureName(RuntimeInformation.ProcessArchitecture);
    internal static string ArchitectureName(Architecture architecture) => architecture switch
    {
        Architecture.Arm64 => "arm64",
        Architecture.X64 => "x64",
        _ => throw new PlatformNotSupportedException("MC Harbor 需要 x64 或 ARM64 Windows。")
    };
    internal static ushort MachineFor(string architecture) => architecture switch
    {
        "arm64" => Arm64Machine,
        "x64" => Amd64Machine,
        _ => throw new ArgumentOutOfRangeException(nameof(architecture))
    };
    internal static bool MatchesMachine(ReadOnlySpan<byte> bytes, ushort expected)
    {
        if (bytes.Length < 64 || bytes[0] != 'M' || bytes[1] != 'Z') return false;
        var offset = BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(0x3c, 4));
        return offset >= 64 && offset <= bytes.Length - 6
            && BinaryPrimitives.ReadUInt32LittleEndian(bytes.Slice(offset, 4)) == 0x4550
            && BinaryPrimitives.ReadUInt16LittleEndian(bytes.Slice(offset + 4, 2)) == expected;
    }
    internal static bool UsesJavaFxModules
    {
        get
        {
            var path = Path.Combine(AppPaths.BackendDirectory, "runtime.json");
            if (!File.Exists(path)) return false;
            using var json = JsonDocument.Parse(File.ReadAllText(path));
            return json.RootElement.TryGetProperty("javaFxMode", out var mode) && mode.GetString() == "modules";
        }
    }
    internal static string LocalTranslationNotice => NativeArchitecture == "arm64"
        ? "当前 ARM64 版的 OPUS-MT 使用独立 x64 兼容进程，需要 Windows 11 24H2 或更新版本；进阶 2B 引擎优先使用原生 ARM64。"
        : "";
}
