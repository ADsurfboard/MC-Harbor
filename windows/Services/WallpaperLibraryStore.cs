using System.Security.Cryptography;
using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal sealed class WallpaperLibraryStore(string directory)
{
    private readonly object _gate = new();
    private string IndexFile => Path.Combine(directory, "index.json");

    internal WallpaperEntry[] Read()
    {
        lock (_gate) return ReadEntries();
    }

    private WallpaperEntry[] ReadEntries()
    {
        if (!File.Exists(IndexFile)) return [];
        var entries = JsonSerializer.Deserialize<WallpaperEntry[]>(File.ReadAllBytes(IndexFile)) ?? [];
        return entries.Where(entry => entry is not null && SafeFileName(entry.FileName))
            .DistinctBy(entry => entry.FileName, StringComparer.OrdinalIgnoreCase)
            .Select(entry => string.IsNullOrWhiteSpace(entry.Name)
                ? entry with { Name = Path.GetFileNameWithoutExtension(entry.FileName) } : entry).ToArray();
    }

    internal async Task<WallpaperEntry> ImportAsync(string source, string name)
    {
        name = ValidName(name);
        var extension = Path.GetExtension(source).ToLowerInvariant();
        if (!SupportedExtension(extension)) throw new IOException("请选择图片或 MP4。");
        PrepareDirectory();
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true);
        if (input.Length > 1_000_000_000) throw new IOException("壁纸文件需小于 1 GB。");
        var digest = Convert.ToHexString(await SHA256.HashDataAsync(input)).ToLowerInvariant();
        var entry = new WallpaperEntry(name, digest + extension);
        var target = Path.Combine(directory, entry.FileName);
        var temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".partial");
        try
        {
            input.Position = 0;
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                65536, useAsync: true))
                await input.CopyToAsync(output);
            lock (_gate)
            {
                if (File.Exists(target)) File.Delete(temporary);
                else File.Move(temporary, target);
                Write(ReadEntries().Where(item => item.FileName != entry.FileName).Append(entry).ToArray());
            }
            return entry;
        }
        finally { File.Delete(temporary); }
    }

    internal WallpaperEntry Rename(WallpaperEntry entry, string name)
    {
        name = ValidName(name);
        lock (_gate)
        {
            var entries = ReadEntries();
            var index = Array.FindIndex(entries, item => item.FileName == entry.FileName);
            if (index < 0) throw new IOException("壁纸已从库中移除。");
            entries[index] = entries[index] with { Name = name };
            Write(entries);
            return entries[index];
        }
    }

    internal void Remove(WallpaperEntry entry)
    {
        if (!SafeFileName(entry.FileName)) throw new IOException("壁纸文件名无效。");
        lock (_gate)
        {
            PrepareDirectory();
            var entries = ReadEntries();
            Write(entries.Where(item => item.FileName != entry.FileName).ToArray());
            try { File.Delete(Path.Combine(directory, entry.FileName)); }
            catch
            {
                Write(entries);
                throw;
            }
        }
    }

    internal string FilePath(WallpaperEntry entry)
    {
        if (!SafeFileName(entry.FileName)) throw new IOException("壁纸文件名无效。");
        return Path.Combine(directory, entry.FileName);
    }

    private void Write(WallpaperEntry[] entries)
    {
        PrepareDirectory();
        AccountStore.WriteAtomically(IndexFile, JsonSerializer.SerializeToUtf8Bytes(entries));
    }

    private void PrepareDirectory()
    {
        Directory.CreateDirectory(directory);
        if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint))
            throw new IOException("壁纸库目录不能使用重解析链接。");
    }

    private static string ValidName(string value)
    {
        value = value.Trim();
        if (value.Length is 0 or > 100 || value.Any(char.IsControl)) throw new IOException("请输入 1–100 字的壁纸名称。");
        return value;
    }

    private static bool SafeFileName(string? value) => !string.IsNullOrWhiteSpace(value)
        && value == Path.GetFileName(value) && !value.Any(character => char.IsControl(character)
            || Path.GetInvalidFileNameChars().Contains(character)) && SupportedExtension(Path.GetExtension(value));

    private static bool SupportedExtension(string extension) =>
        new[] { ".png", ".jpg", ".jpeg", ".bmp", ".mp4" }.Contains(extension, StringComparer.OrdinalIgnoreCase);
}
