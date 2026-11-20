using System.Diagnostics;
using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal sealed class ShortcutActivationInbox(string directory)
{
    private static readonly TimeSpan RequestLifetime = TimeSpan.FromSeconds(60);

    internal PendingRequest Create(string? instance)
    {
        Directory.CreateDirectory(directory);
        var request = new Request(Guid.NewGuid(), instance, DateTimeOffset.UtcNow);
        var path = Path.Combine(directory, request.Id.ToString("N") + ".json");
        AccountStore.WriteAtomically(path, JsonSerializer.SerializeToUtf8Bytes(request));
        return new PendingRequest(path);
    }

    internal int Consume(Action<string?> receive)
    {
        if (!Directory.Exists(directory)) return 0;
        var consumed = 0;
        foreach (var path in Directory.EnumerateFiles(directory, "*.json").Order(StringComparer.Ordinal))
        {
            if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out var id)) continue;
            var claimed = path + ".processing";
            try { File.Move(path, claimed); }
            catch (IOException) { continue; }
            try
            {
                var bytes = File.ReadAllBytes(claimed);
                if (bytes.Length > 16384) continue;
                var request = JsonSerializer.Deserialize<Request>(bytes);
                if (request is null || request.Id != id
                    || DateTimeOffset.UtcNow - request.Created > RequestLifetime
                    || request.Created - DateTimeOffset.UtcNow > TimeSpan.FromSeconds(5)) continue;
                receive(request.Instance);
                File.WriteAllText(path + ".received", "");
                consumed++;
            }
            catch (JsonException error) { StartupDiagnostics.Write("快捷启动请求无法读取", error); }
            finally { TryDelete(claimed); }
        }
        foreach (var receipt in Directory.EnumerateFiles(directory, "*.received"))
            if (DateTime.UtcNow - File.GetLastWriteTimeUtc(receipt) > RequestLifetime) TryDelete(receipt);
        return consumed;
    }

    internal sealed class PendingRequest(string path) : IDisposable
    {
        internal async Task<bool> WaitForReceiptAsync(TimeSpan timeout)
        {
            var started = Stopwatch.StartNew();
            var receipt = path + ".received";
            while (started.Elapsed < timeout)
            {
                if (File.Exists(receipt)) return true;
                await Task.Delay(50).ConfigureAwait(false);
            }
            return File.Exists(receipt);
        }

        public void Dispose()
        {
            TryDelete(path);
            TryDelete(path + ".received");
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed record Request(Guid Id, string? Instance, DateTimeOffset Created);
}
