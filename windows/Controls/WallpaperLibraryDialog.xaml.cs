using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace MCHarbor.Windows.Controls;

public sealed partial class WallpaperLibraryDialog : ContentDialog
{
    private readonly MainWindow _owner;
    private MediaPlayer? _player;
    private long _previewSequence;
    private bool _open;
    private bool _busy;
    private bool _resumePreview;
    private readonly HashSet<WallpaperLibraryItem> _thumbnails = [];

    internal WallpaperLibraryDialog(MainWindow owner, ResourceDictionary resources)
    {
        _owner = owner;
        Resources["HarborPill"] = resources["HarborPill"];
        Resources["HarborProminentPill"] = resources["HarborProminentPill"];
        InitializeComponent();
        Opened += (_, _) =>
        {
            _open = true;
            _owner.Activated += Owner_Activated;
            _owner.Closed += Owner_Closed;
            Reload(_owner.ActiveWallpaper);
        };
        Closed += (_, _) => ClosePreview();
    }

    internal void SetContentWidth(double width) => LibraryLayout.Width = width;

    private void LibraryLayout_SizeChanged(object sender, SizeChangedEventArgs e) =>
        LibraryLayout.ColumnDefinitions[1].Width = new GridLength(e.NewSize.Width < 630 ? 250 : 300);

    private void Items_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (Items.ItemsPanelRoot is not ItemsWrapGrid panel || e.NewSize.Width < 1) return;
        var width = Math.Max(1, e.NewSize.Width - 12);
        var columns = Math.Max(1, (int)(width / 155));
        panel.MaximumRowsOrColumns = columns;
        panel.ItemWidth = width / columns;
    }

    private void Reload(string selected)
    {
        _thumbnails.Clear();
        var items = _owner.LibraryWallpapers.Select(entry => new WallpaperLibraryItem(entry)).ToArray();
        Items.ItemsSource = items;
        Items.SelectedItem = items.FirstOrDefault(item => item.Entry.FileName == selected) ?? items.First();
        LibrarySummary.Text = $"{items.Length - 1} 张壁纸";
        UpdateActions();
    }

    private async void Items_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || !_open || args.Item is not WallpaperLibraryItem item
            || item.Entry.FileName.Length == 0 || !_thumbnails.Add(item)) return;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(_owner.WallpaperFilePath(item.Entry));
            using var thumbnail = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, 320, ThumbnailOptions.ResizeThumbnail);
            if (_open && thumbnail is { Type: ThumbnailType.Image }) await item.Thumbnail.SetSourceAsync(thumbnail);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
            or System.Runtime.InteropServices.COMException)
        {
            // Keep the entry selectable so a missing or undecodable file can be removed from the library.
        }
    }

    private async void Items_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_open) return;
        var sequence = ++_previewSequence;
        ReleasePlayer();
        ImagePreview.Source = null;
        ImagePreview.Visibility = VideoPreview.Visibility = Visibility.Collapsed;
        PreviewPlaceholder.Visibility = Visibility.Visible;
        RemoveConfirmation.Visibility = Visibility.Collapsed;
        LibraryStatus.Text = "";
        if (Items.SelectedItem is not WallpaperLibraryItem item)
        {
            PreviewPlaceholder.Text = "选择壁纸查看预览";
            return;
        }
        NameInput.Text = item.Entry.Name;
        PreviewKind.Text = item.Kind;
        UpdateActions();
        if (item.Entry.FileName.Length == 0)
        {
            PreviewPlaceholder.Text = "Harbor 默认渐变";
            return;
        }
        PreviewPlaceholder.Text = "正在读取预览…";
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(_owner.WallpaperFilePath(item.Entry));
            if (!_open || sequence != _previewSequence) return;
            if (item.Entry.Video)
            {
                var player = new MediaPlayer { IsMuted = true, IsLoopingEnabled = true };
                _player = player;
                player.MediaFailed += (_, _) => DispatcherQueue.TryEnqueue(() =>
                {
                    if (!_open || sequence != _previewSequence) return;
                    ReleasePlayer();
                    VideoPreview.Visibility = Visibility.Collapsed;
                    PreviewPlaceholder.Text = "视频无法预览，请检查文件或视频编码。";
                    PreviewPlaceholder.Visibility = Visibility.Visible;
                });
                player.MediaOpened += (_, _) => DispatcherQueue.TryEnqueue(() =>
                {
                    if (_open && sequence == _previewSequence) PreviewPlaceholder.Visibility = Visibility.Collapsed;
                });
                VideoPreview.SetMediaPlayer(player);
                VideoPreview.Visibility = Visibility.Visible;
                player.Source = MediaSource.CreateFromStorageFile(file);
                player.Play();
            }
            else
            {
                var image = new BitmapImage { DecodePixelWidth = 960 };
                image.ImageFailed += (_, _) =>
                {
                    if (!_open || sequence != _previewSequence) return;
                    ImagePreview.Visibility = Visibility.Collapsed;
                    PreviewPlaceholder.Text = "图片无法预览，请检查文件。";
                    PreviewPlaceholder.Visibility = Visibility.Visible;
                };
                image.ImageOpened += (_, _) =>
                {
                    if (_open && sequence == _previewSequence) PreviewPlaceholder.Visibility = Visibility.Collapsed;
                };
                ImagePreview.Source = image;
                ImagePreview.Visibility = Visibility.Visible;
                using var stream = await file.OpenReadAsync();
                if (_open && sequence == _previewSequence) await image.SetSourceAsync(stream);
            }
        }
        catch (Exception error)
        {
            if (!_open || sequence != _previewSequence) return;
            ReleasePlayer();
            PreviewPlaceholder.Text = "预览不可用";
            LibraryStatus.Text = error.Message;
        }
    }

    private void UpdateActions()
    {
        var item = Items.SelectedItem as WallpaperLibraryItem;
        var managed = item?.Entry.FileName.Length > 0;
        Items.IsEnabled = ImportButton.IsEnabled = !_busy;
        NameInput.IsEnabled = RenameButton.IsEnabled = RemoveButton.IsEnabled = !_busy && managed;
        ApplyButton.IsEnabled = !_busy && item is not null;
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (_busy) return;
        _busy = true;
        UpdateActions();
        try { await action(); }
        catch (Exception error) { LibraryStatus.Text = error.Message; }
        finally { _busy = false; UpdateActions(); }
    }

    private async void Import_Click(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        var entry = await _owner.ImportLibraryWallpaperAsync();
        if (entry is not null && _open) Reload(entry.FileName);
    });

    private async void Rename_Click(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        if (Items.SelectedItem is not WallpaperLibraryItem item) return;
        var entry = await _owner.RenameLibraryWallpaperAsync(item.Entry, NameInput.Text);
        if (_open) Reload(entry.FileName);
    });

    private async void Apply_Click(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        if (Items.SelectedItem is not WallpaperLibraryItem item) return;
        await _owner.UseLibraryWallpaperAsync(item.Entry);
        LibraryStatus.Text = "壁纸已切换";
    });

    private void Remove_Click(object sender, RoutedEventArgs e) => RemoveConfirmation.Visibility = Visibility.Visible;
    private void CancelRemove_Click(object sender, RoutedEventArgs e) => RemoveConfirmation.Visibility = Visibility.Collapsed;

    private async void ConfirmRemove_Click(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        if (Items.SelectedItem is not WallpaperLibraryItem item || item.Entry.FileName.Length == 0) return;
        ++_previewSequence;
        ReleasePlayer();
        ImagePreview.Source = null;
        await _owner.RemoveLibraryWallpaperAsync(item.Entry);
        if (_open) Reload(_owner.ActiveWallpaper);
    });

    private void Owner_Activated(object sender, WindowActivatedEventArgs e)
    {
        if (_player is not { } player) return;
        if (e.WindowActivationState == WindowActivationState.Deactivated)
        {
            _resumePreview = player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
            player.Pause();
        }
        else if (_resumePreview)
        {
            _resumePreview = false;
            player.Play();
        }
    }

    private void Owner_Closed(object sender, WindowEventArgs e) => ClosePreview();

    private void ReleasePlayer()
    {
        _resumePreview = false;
        VideoPreview.SetMediaPlayer(null);
        var player = _player;
        _player = null;
        if (player is null) return;
        player.Pause();
        player.Dispose();
    }

    private void ClosePreview()
    {
        _open = false;
        ++_previewSequence;
        _owner.Activated -= Owner_Activated;
        _owner.Closed -= Owner_Closed;
        ReleasePlayer();
        ImagePreview.Source = null;
        Items.ItemsSource = null;
        _thumbnails.Clear();
    }
}

public sealed record WallpaperLibraryItem(WallpaperEntry Entry)
{
    public BitmapImage Thumbnail { get; } = new();
    public string Kind => Entry.FileName.Length == 0 ? "默认背景" : Entry.Video ? "视频" : "图片";
}
