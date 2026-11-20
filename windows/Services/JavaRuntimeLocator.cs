namespace MCHarbor.Windows.Services;

internal static class JavaRuntimeLocator
{
    public static string? FindLauncherJava()
    {
        var bundled = Path.Combine(AppPaths.ApplicationDirectory, "Runtime", "bin", "java.exe");
        if (File.Exists(bundled)) return bundled;

        var javaHome = Environment.GetEnvironmentVariable("JAVA_HOME");
        if (!string.IsNullOrWhiteSpace(javaHome))
        {
            var candidate = Path.Combine(javaHome, "bin", "java.exe");
            if (File.Exists(candidate)) return candidate;
        }

        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var candidate = Path.Combine(directory, "java.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
