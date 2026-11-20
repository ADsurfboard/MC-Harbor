namespace MCHarbor.Windows.Models;

public sealed record ModFile(
    string Path,
    string Name,
    string Version,
    string ModId,
    string Loader,
    long Size,
    bool Enabled)
{
    public string Details => $"{ModId} · {Version} · {Loader} · {Size / 1024d / 1024d:F1} MB";
    public string Status => Enabled ? "已启用" : "已停用";
}
