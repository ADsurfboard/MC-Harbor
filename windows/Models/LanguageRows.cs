namespace MCHarbor.Windows.Models;

public sealed record LanguageSource(string Id, string Name, bool Enabled, int Entries, int Translated)
{
    public string Progress => $"{Translated} / {Entries} 条" + (Enabled ? "" : " · 已停用");
}

public sealed record LanguageEntry(string Id, string Key, string Source, string Translation, string Origin, string Issue);
