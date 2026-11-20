using Microsoft.UI.Xaml;

namespace MCHarbor.Windows.Models;

public sealed record InstanceResource(
    string Path,
    string Name,
    string Kind,
    bool Enabled,
    int LanguageFiles)
{
    public string Category => Kind switch
    {
        "mods" => "模组",
        "resourcepacks" => "资源包",
        "shaderpacks" => "光影",
        "saves" => "存档",
        _ => Kind
    };

    public string Details => LanguageFiles > 0
        ? $"{Category} · {LanguageFiles} 个语言文件"
        : Category;

    public string Status => Kind == "saves" ? "世界存档" : Enabled ? "已启用" : "已停用";
    public bool CanToggle => Kind is "mods" or "resourcepacks" or "shaderpacks";
    public Visibility ToggleVisibility => CanToggle ? Visibility.Visible : Visibility.Collapsed;
    public Visibility WorldActions => Kind == "saves" && Directory.Exists(Path)
        ? Visibility.Visible : Visibility.Collapsed;
}
