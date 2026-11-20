using System.Text.Json;

namespace MCHarbor.Windows.Services;

internal sealed class InterfaceSoundbank
{
    private sealed record CueRange(int Offset, int Length);

    private readonly byte[] _data;
    private readonly int _payloadOffset;
    private readonly Dictionary<string, CueRange> _cues;

    private InterfaceSoundbank(byte[] data, int payloadOffset, Dictionary<string, CueRange> cues)
    {
        _data = data;
        _payloadOffset = payloadOffset;
        _cues = cues;
    }

    public static InterfaceSoundbank? TryLoad(string path)
    {
        try
        {
            var data = File.ReadAllBytes(path);
            if (data.Length < 13 || !data.AsSpan(0, 8).SequenceEqual("MCHSFX01"u8)) return null;
            var headerLength = BitConverter.ToInt32(data, 8);
            var payloadOffset = checked(12 + headerLength);
            if (headerLength is <= 0 or > 100_000 || payloadOffset >= data.Length) return null;

            using var document = JsonDocument.Parse(data.AsMemory(12, headerLength));
            if (!document.RootElement.TryGetProperty("entries", out var entries)
                || entries.ValueKind != JsonValueKind.Object) return null;

            var cues = new Dictionary<string, CueRange>(StringComparer.Ordinal);
            foreach (var cue in entries.EnumerateObject())
            {
                if (!cue.Value.TryGetProperty("offset", out var offsetNode)
                    || !cue.Value.TryGetProperty("length", out var lengthNode)
                    || !offsetNode.TryGetInt32(out var offset)
                    || !lengthNode.TryGetInt32(out var length)
                    || offset < 0 || length <= 0 || offset > data.Length - payloadOffset - length)
                    continue;
                cues[cue.Name] = new CueRange(offset, length);
            }
            return cues.Count == 0 ? null : new InterfaceSoundbank(data, payloadOffset, cues);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or OverflowException)
        {
            return null;
        }
    }

    public byte[]? GetCue(string cue) => _cues.TryGetValue(cue, out var range)
        ? _data.AsSpan(_payloadOffset + range.Offset, range.Length).ToArray()
        : null;
}
