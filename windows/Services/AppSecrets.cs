using System.Security.Cryptography;
using System.Text;

namespace MCHarbor.Windows.Services;

internal static class AppSecrets
{
    public static string? Read(string key)
    {
        var file = SecretPath(key);
        if (!File.Exists(file)) return null;
        var clear = AccountStore.Unprotect(File.ReadAllBytes(file));
        try { return Encoding.UTF8.GetString(clear); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public static void Save(string key, string value)
    {
        var clear = Encoding.UTF8.GetBytes(value);
        try { AccountStore.WriteAtomically(SecretPath(key), AccountStore.Protect(clear)); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public static void Remove(string key) => File.Delete(SecretPath(key));

    private static string SecretPath(string key) => Path.Combine(AppPaths.DataDirectory, "secrets",
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))) + ".dpapi");
}
