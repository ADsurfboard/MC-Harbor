using System.Diagnostics;

namespace MCHarbor.Windows.Services;

internal static class StartupDiagnostics
{
    public static string? Write(string context, Exception error)
    {
        // Exception messages from Java and account flows can contain user data.
        var entry = $"{DateTimeOffset.Now:O} {context}: {error.GetType().FullName} (0x{error.HResult:X8})"
            + Environment.NewLine + error.StackTrace + Environment.NewLine;
        Trace.WriteLine(entry);
        foreach (var folder in new[] { AppPaths.DataDirectory, Path.GetTempPath() })
        {
            try
            {
                Directory.CreateDirectory(folder);
                var path = Path.Combine(folder, "MC-Harbor-startup.log");
                File.AppendAllText(path, entry);
                return path;
            }
            catch (Exception writeError) when (writeError is IOException or UnauthorizedAccessException) { }
        }
        return null;
    }
}
