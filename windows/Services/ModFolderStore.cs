using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal static class ModFolderStore
{
    private static string Root => Path.Combine(AppPaths.DataDirectory, "mod-collections");
    private static string Index => Path.Combine(Root, "folders.json");
    private static string FilesDirectory => Path.Combine(Root, "files");

    public static ModFolder[] Read() => File.Exists(Index)
        ? JsonSerializer.Deserialize<ModFolder[]>(File.ReadAllBytes(Index)) ?? []
        : [];

    public static void Write(ModFolder[] folders) =>
        AccountStore.WriteAtomically(Index, JsonSerializer.SerializeToUtf8Bytes(folders));

    public static async Task<ModFolderEntry> CollectAsync(string file, string name, string? game, string? loader,
        CancellationToken cancellation)
    {
        var fileName = Path.GetFileName(file);
        if (fileName.EndsWith(".jar.disabled", StringComparison.OrdinalIgnoreCase))
            fileName = fileName[..^".disabled".Length];
        if (!fileName.EndsWith(".jar", StringComparison.OrdinalIgnoreCase))
            throw new IOException("请选择 JAR 模组。");
        if ((File.GetAttributes(file) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            throw new IOException("请选择普通的模组文件。");

        Directory.CreateDirectory(FilesDirectory);
        var temporary = Path.Combine(FilesDirectory, $".harbor-{Guid.NewGuid():N}.partial");
        try
        {
            await using (var input = File.OpenRead(file))
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                if (input.Length is < 1 or > 1_000_000_000)
                    throw new IOException("模组文件为空或超过 1 GB。");
                await input.CopyToAsync(output, cancellation);
            }
            using (var archive = ZipFile.OpenRead(temporary))
                if (archive.Entries.Count == 0) throw new IOException("模组归档为空。");
            var hash = await HashAsync(temporary, cancellation);
            var destination = Path.Combine(FilesDirectory, hash + ".jar");
            if (File.Exists(destination))
            {
                if (await HashAsync(destination, cancellation) != hash)
                    throw new IOException("模组夹中的同摘要文件已损坏。");
            }
            else File.Move(temporary, destination);
            return new ModFolderEntry(hash, name, fileName, null, game, loader);
        }
        finally { File.Delete(temporary); }
    }

    public static async Task CopyToAsync(ModFolderEntry item, string destination, CancellationToken cancellation)
    {
        if (item.Id.Length != 64 || !item.Id.All(char.IsAsciiHexDigit))
            throw new IOException("模组夹文件标识无效。");
        var path = Path.Combine(FilesDirectory, item.Id + ".jar");
        if (!File.Exists(path)) throw new IOException($"模组夹缺少文件：{item.Name}");
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("模组夹文件是链接。");
        await using (var input = File.OpenRead(path))
        await using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            await input.CopyToAsync(output, cancellation);
        if (!string.Equals(await HashAsync(destination, cancellation), item.Id, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"模组夹文件摘要校验失败：{item.Name}");
    }

    private static async Task<string> HashAsync(string path, CancellationToken cancellation)
    {
        await using var source = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(source, cancellation));
    }
}

public sealed record ModFolder(Guid Id, string Name, ModFolderEntry[] Entries)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public string EntryCountLabel => $"{Entries.Length} 个模组";
}

public sealed record ModFolderEntry(string Id, string Name, string? FileName, CatalogProject? Project, string? Game, string? Loader)
{
    public string Details => Project is { } project
        ? $"{(project.Source == "modrinth" ? "Modrinth" : "CurseForge")} · {project.Author}"
        : string.IsNullOrEmpty(Game) ? $"本地 · {FileName}" : $"本地 · Minecraft {Game} · {Loader} · {FileName}";
}
