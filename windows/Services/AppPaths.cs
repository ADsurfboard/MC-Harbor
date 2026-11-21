using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal static class AppPaths
{
    private static readonly object PreferencesLock = new();
    private static Dictionary<string, string>? _preferences;

    public static string ApplicationDirectory { get; } = AppContext.BaseDirectory;
    public static string Version { get; } = typeof(AppPaths).Assembly.GetName().Version?.ToString(4) ?? "1.7.1.1";
    public static string DataDirectory { get; } = ResolveDataDirectory();
    public static string DefaultGameRoot { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), ".minecraft");
    public static string BackendDirectory => Path.Combine(ApplicationDirectory, "Backend");
    public static string BackendJar => Path.Combine(BackendDirectory, "Backend.jar");
    public static string HmclJar => Path.Combine(BackendDirectory, "HMCLCore.jar");
    public static string JavaFxDirectory => Path.Combine(BackendDirectory, "javafx");
    public static string PreferencesFile => Path.Combine(DataDirectory, "preferences.json");
    public static string AccountsFile => Path.Combine(DataDirectory, "accounts.json");
    public static string AccountSecretsDirectory => Path.Combine(DataDirectory, "account-secrets");

    public static string GameRoot
    {
        get
        {
            lock (PreferencesLock)
            {
                EnsurePreferencesLoaded();
                if (_preferences!.TryGetValue("gameRoot", out var path) && !string.IsNullOrWhiteSpace(path))
                {
                    try { return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)); }
                    catch (ArgumentException) { }
                    catch (NotSupportedException) { }
                }
            }
            return DefaultGameRoot;
        }
    }

    public static void SetGameRoot(string path)
    {
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(fullPath);
        SetPreference("gameRoot", fullPath);
    }

    public static string? SelectedAccountId
    {
        get
        {
            lock (PreferencesLock)
            {
                EnsurePreferencesLoaded();
                return _preferences!.GetValueOrDefault("selectedAccount");
            }
        }
        set
        {
            lock (PreferencesLock)
            {
                EnsurePreferencesLoaded();
                var updated = new Dictionary<string, string>(_preferences!);
                if (string.IsNullOrWhiteSpace(value)) updated.Remove("selectedAccount");
                else updated["selectedAccount"] = value;
                AccountStore.WriteAtomically(PreferencesFile, JsonSerializer.SerializeToUtf8Bytes(updated, JsonOptions));
                _preferences = updated;
            }
        }
    }

    public static string OfflineUsername
    {
        get
        {
            lock (PreferencesLock)
            {
                EnsurePreferencesLoaded();
                return _preferences!.GetValueOrDefault("offlineUsername", "Player");
            }
        }
        set => SetPreference("offlineUsername", value);
    }

    public static string GetPreference(string key, string fallback = "")
    {
        lock (PreferencesLock)
        {
            EnsurePreferencesLoaded();
            return _preferences!.GetValueOrDefault(key, fallback);
        }
    }

    public static void SetPreference(string key, string value) => SetPreferences((key, value));

    public static void SetPreferences(params (string Key, string? Value)[] values)
    {
        lock (PreferencesLock)
        {
            EnsurePreferencesLoaded();
            var updated = new Dictionary<string, string>(_preferences!);
            foreach (var (key, value) in values)
            {
                if (value is null) updated.Remove(key);
                else updated[key] = value;
            }
            AccountStore.WriteAtomically(PreferencesFile, JsonSerializer.SerializeToUtf8Bytes(updated, JsonOptions));
            _preferences = updated;
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static string ResolveDataDirectory()
    {
        var marker = Path.Combine(AppContext.BaseDirectory, "MCHarbor.portable");
        return File.Exists(marker)
            ? Path.Combine(AppContext.BaseDirectory, "MCHarborData")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MCHarbor");
    }

    private static void EnsurePreferencesLoaded()
    {
        if (_preferences is not null) return;
        try
        {
            _preferences = File.Exists(PreferencesFile)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(PreferencesFile)) ?? new()
                : new();
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            _preferences = new();
        }
    }
}
