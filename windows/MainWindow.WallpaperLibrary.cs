using MCHarbor.Windows.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    internal WallpaperEntry[] LibraryWallpapers =>
        [new WallpaperEntry("Harbor 渐变", ""), .. _wallpapers];

    internal string ActiveWallpaper => Services.AppPaths.GetPreference("wallpaper");

    internal string WallpaperFilePath(WallpaperEntry entry) => WallpaperLibrary.FilePath(entry);

    private async void OpenWallpaperLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (_wallpaperLibraryOpen) return;
        _wallpaperLibraryOpen = true;
        UpdateWallpaperPlayback();
        try
        {
            await RefreshWallpaperLibraryAsync(applyWallpaper: false);
            _wallpaperLibraryDialog = new WallpaperLibraryDialog(this, RootShell.Resources)
            {
                XamlRoot = RootShell.XamlRoot,
                RequestedTheme = RootShell.ActualTheme
            };
            _wallpaperLibraryDialog.Resources["ContentDialogMaxWidth"] = 1020d;
            _wallpaperLibraryDialog.SetContentWidth(Math.Max(400, Math.Min(900, RootShell.ActualWidth - 120)));
            await _wallpaperLibraryDialog.ShowAsync();
        }
        catch (Exception error) { ShowStatus("壁纸库无法打开：" + error.Message, InfoBarSeverity.Warning); }
        finally
        {
            _wallpaperLibraryDialog = null;
            _wallpaperLibraryOpen = false;
            UpdateWallpaperPlayback();
        }
    }

    internal async Task<WallpaperEntry?> ImportLibraryWallpaperAsync()
    {
        var file = await PickFileAsync(".png", ".jpg", ".jpeg", ".bmp", ".mp4");
        if (file is null) return null;
        var name = Path.GetFileNameWithoutExtension(file.Name);
        var entry = await WallpaperLibrary.ImportAsync(file.Path, name[..Math.Min(100, name.Length)]);
        await RefreshWallpaperLibraryAsync(applyWallpaper: false);
        return entry;
    }

    internal async Task<WallpaperEntry> RenameLibraryWallpaperAsync(WallpaperEntry entry, string name)
    {
        var renamed = WallpaperLibrary.Rename(entry, name);
        await RefreshWallpaperLibraryAsync(applyWallpaper: false);
        return renamed;
    }

    internal async Task UseLibraryWallpaperAsync(WallpaperEntry entry)
    {
        SaveSetting("wallpaper", entry.FileName);
        await RefreshWallpaperLibraryAsync();
    }

    internal async Task RemoveLibraryWallpaperAsync(WallpaperEntry entry)
    {
        var active = ActiveWallpaper == entry.FileName;
        if (active) StopWallpaper();
        try { WallpaperLibrary.Remove(entry); }
        catch
        {
            if (active) await ApplyWallpaperAsync(entry);
            throw;
        }
        if (active) SaveSetting("wallpaper", "");
        await RefreshWallpaperLibraryAsync(applyWallpaper: active);
    }
}
