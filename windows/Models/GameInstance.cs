namespace MCHarbor.Windows.Models;

public sealed record GameInstance(
    string Id,
    string Version,
    string Loader,
    string Directory,
    string RunDirectory,
    string? IconPath,
    DateTimeOffset Modified)
{
    public bool Favorite { get; init; }
    public string FavoriteSymbol => Favorite ? "★" : "☆";
    public string DisplayName => Favorite ? $"★ {Id}" : Id;

    public string Artwork => new Uri(IconPath ?? System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Loaders",
        (Loader == "vanilla" ? "grass" : Loader) + ".png")).AbsoluteUri;
}
