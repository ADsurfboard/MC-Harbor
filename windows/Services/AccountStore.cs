using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using MCHarbor.Windows.Models;

namespace MCHarbor.Windows.Services;

internal static class AccountStore
{
    private const uint UiForbidden = 0x1;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("MC Harbor Windows account store v1");
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("Crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref DataBlob input, string description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("Crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("Kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static IReadOnlyList<StoredAccount> ReadAll()
    {
        if (!File.Exists(AppPaths.AccountsFile)) return [];
        return JsonSerializer.Deserialize<List<StoredAccount>>(File.ReadAllText(AppPaths.AccountsFile)) ?? [];
    }

    public static StoredAccount Save(JsonObject serializedAccount, bool requiresReauth = false)
    {
        var metadata = serializedAccount["metadata"]?.AsObject()
            ?? throw new InvalidDataException("账号返回缺少显示信息。");
        var hmclMetadata = serializedAccount["hmclMetadata"]?.AsObject()
            ?? throw new InvalidDataException("账号返回缺少 HMCL 账号数据。");
        var privateData = serializedAccount["privateData"]?.AsObject() ?? new JsonObject();
        var id = GetString(metadata, "id");
        if (string.IsNullOrWhiteSpace(id)) throw new InvalidDataException("账号返回缺少唯一标识。");

        var secret = new JsonObject
        {
            ["hmclMetadata"] = hmclMetadata.DeepClone(),
            ["privateData"] = privateData.DeepClone()
        };
        var clearBytes = Encoding.UTF8.GetBytes(secret.ToJsonString());
        byte[] protectedBytes;
        try { protectedBytes = Protect(clearBytes); }
        finally { CryptographicOperations.ZeroMemory(clearBytes); }

        Directory.CreateDirectory(AppPaths.AccountSecretsDirectory);
        var secretPath = GetSecretPath(id);
        WriteAtomically(secretPath, protectedBytes);
        CryptographicOperations.ZeroMemory(protectedBytes);

        var account = new StoredAccount(
            id,
            GetString(metadata, "name") ?? "未知账号",
            GetString(metadata, "uuid") ?? "",
            GetString(metadata, "kind") ?? "offline",
            requiresReauth || serializedAccount["requiresReauth"]?.GetValue<bool>() == true);
        var records = ReadAll().Where(item => item.Id != id).Append(account).ToList();
        WriteAtomically(AppPaths.AccountsFile, JsonSerializer.SerializeToUtf8Bytes(records, JsonOptions));
        return account;
    }

    public static JsonObject? LoadPayload(string id)
    {
        var account = ReadAll().FirstOrDefault(item => item.Id == id);
        if (account is null || account.RequiresReauth) return null;
        var path = GetSecretPath(id);
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return null;
        var protectedBytes = File.ReadAllBytes(path);
        var clearBytes = Unprotect(protectedBytes);
        CryptographicOperations.ZeroMemory(protectedBytes);
        try { return JsonNode.Parse(clearBytes)?.AsObject(); }
        finally { CryptographicOperations.ZeroMemory(clearBytes); }
    }

    public static void Select(string? id)
    {
        if (id is not null && ReadAll().All(item => item.Id != id))
            throw new InvalidOperationException("所选账号已不在账号列表中。");
        AppPaths.SelectedAccountId = id;
    }

    private static string? GetString(JsonObject value, string key)
    {
        try { return value[key]?.GetValue<string>(); }
        catch (InvalidOperationException) { return null; }
    }

    private static string GetSecretPath(string id)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).ToLowerInvariant();
        return Path.Combine(AppPaths.AccountSecretsDirectory, hash + ".dpapi");
    }

    internal static byte[] Protect(byte[] clearText) => Transform(clearText, protect: true);
    internal static byte[] Unprotect(byte[] protectedText) => Transform(protectedText, protect: false);

    private static byte[] Transform(byte[] inputBytes, bool protect)
    {
        var input = Allocate(inputBytes);
        var entropy = Allocate(Entropy);
        DataBlob output = default;
        try
        {
            var success = protect
                ? CryptProtectData(ref input, "MC Harbor account", ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows 凭据保护操作失败。");
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        finally
        {
            ZeroAndFree(input);
            ZeroAndFree(entropy);
            if (output.Data != IntPtr.Zero) LocalFree(output.Data);
        }
    }

    private static DataBlob Allocate(byte[] data)
    {
        var pointer = Marshal.AllocHGlobal(data.Length);
        Marshal.Copy(data, 0, pointer, data.Length);
        return new DataBlob { Size = data.Length, Data = pointer };
    }

    private static void ZeroAndFree(DataBlob blob)
    {
        if (blob.Data == IntPtr.Zero) return;
        for (var offset = 0; offset < blob.Size; offset += 1) Marshal.WriteByte(blob.Data, offset, 0);
        Marshal.FreeHGlobal(blob.Data);
    }

    internal static void WriteAtomically(string destination, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
        }
    }
}
