using System.Globalization;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.Graphics.Canvas;
using MCHarbor.Windows.Services;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace MCHarbor.Windows;

public sealed record WallpaperEntry(string Name, string FileName)
{
    public bool Video => FileName.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase);
}

public sealed partial class MainWindow
{
    private const int DefaultGlassTransparency = 40;
    private const int DefaultGlassShadow = 24;
    private const int DefaultGlassBlur = 18;
    private readonly AccessibilitySettings _accessibility = new();
    private readonly UISettings _uiSettings = new();
    private WallpaperEntry[] _wallpapers = [];
    private volatile MediaPlayer? _wallpaperPlayer;
    private MediaPlayer? _voicePlayer;
    private MediaPlayer? _interfacePlayer;
    private InMemoryRandomAccessStream? _interfaceAudioStream;
    private InterfaceSoundbank? _interfaceSoundbank;
    private CanvasDevice? _wallpaperCanvasDevice;
    private CanvasRenderTarget? _wallpaperFrameBitmap;
    private CanvasBitmap? _wallpaperStillBitmap;
    private volatile bool _wallpaperFrameReady;
    private long _wallpaperRequest;
    private DependencyObject? _lastHoverSoundTarget;
    private DateTimeOffset _lastFocusSound = DateTimeOffset.MinValue;
    private bool _appearanceReady;
    private bool _resettingGlass;
    private bool _appearanceWindowLoaded;
    private bool _glassMotionActive;
    private bool _glassLayerActive;
    private volatile bool _playingWallpaper;
    private bool _settingWallpaper;
    private bool _welcomePlayed;
    private bool _colorEventsAttached;
    private bool _contrastEventsAttached;
    private int _wallpaperFrameQueued;
    private long _lastWallpaperFrameTimestamp;
    private static string WallpaperDirectory => Path.Combine(AppPaths.DataDirectory, "wallpapers");
    private static readonly WallpaperLibraryStore WallpaperLibrary = new(WallpaperDirectory);
    private bool _wallpaperLibraryOpen;
    private Controls.WallpaperLibraryDialog? _wallpaperLibraryDialog;

    private void InitializeAppearance()
    {
        ThemeMode.SelectedIndex = AppPaths.GetPreference("theme") switch { "light" => 1, "dark" => 2, _ => 0 };
        InvertTheme.IsOn = PreferenceEnabled("invertTheme");
        GlassEnabled.IsOn = PreferenceEnabled("glass", true);
        GlassTransparency.Value = ReadSettingNumber("glassTransparency", DefaultGlassTransparency, 0, 100);
        GlassShadow.Value = ReadSettingNumber("glassShadow", DefaultGlassShadow, 0, 100);
        GlassBlur.Value = ReadSettingNumber("glassBlur", DefaultGlassBlur, 0, 40);
        SidebarGlassBlur.Value = ReadSettingNumber("glassSidebarBlur", GlassBlur.Value, 0, 40);
        AccountListGlassBlur.Value = ReadSettingNumber("glassAccountListBlur", GlassBlur.Value, 0, 40);
        AccountDetailsGlassBlur.Value = ReadSettingNumber("glassAccountDetailsBlur", GlassBlur.Value, 0, 40);
        WallpaperDimming.Value = ReadSettingNumber("wallpaperDimming", 16, 0, 75);
        WallpaperSoftness.Value = ReadSettingNumber("wallpaperSoftness", 0, 0, 24);
        ReduceMotion.IsOn = PreferenceEnabled("reduceMotion");
        PerformanceMode.IsOn = PreferenceEnabled("performanceMode", true);
        WelcomeVoice.SelectedIndex = (int)ReadSettingNumber("welcomeVoice", 1, 0, 4);
        WelcomeVolume.Value = ReadSettingNumber("welcomeVolume", 65, 0, 100);
        InterfaceSounds.IsOn = PreferenceEnabled("interfaceSounds", true);
        InterfaceVolume.Value = ReadSettingNumber("interfaceVolume", 48, 0, 100);
        GameMemory.Value = ReadSettingNumber("gameMemory", 3072, 1024, 6144);
        CompleteDependencies.IsOn = PreferenceEnabled("completeDependencies");
        DownloadSource.SelectedIndex = AppPaths.GetPreference("downloadSource") == "official" ? 1 : 0;
        DataDirectoryText.Text = AppPaths.DataDirectory;
        WindowsVersionText.Text = $"MC Harbor for Windows {AppPaths.Version} · {WindowsPlatform.ClientArchitecture.ToUpperInvariant()}";

        _appearanceReady = true;
        ApplyTheme();
        // Some Windows 10 desktops do not expose the notification source to unpackaged apps.
        // Read the settings at startup and on activation even if subscribing is unavailable.
        try
        {
            _accessibility.HighContrastChanged += OnHighContrastChanged;
            _contrastEventsAttached = true;
        }
        catch (System.Runtime.InteropServices.COMException) { }
        try
        {
            _uiSettings.ColorValuesChanged += OnColorsChanged;
            _colorEventsAttached = true;
        }
        catch (System.Runtime.InteropServices.COMException) { }
        Activated += OnAppearanceActivated;
        AppWindow.Changed += OnAppearanceWindowChanged;
        Closed += OnAppearanceClosed;
        RootShell.AddHandler(UIElement.PointerMovedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler(OnGlassPointerMoved), true);
        RootShell.AddHandler(UIElement.PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler(OnGlassPointerPressed), true);
        RootShell.AddHandler(UIElement.KeyDownEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler(OnGlassKeyDown), true);
        RootShell.PointerExited += OnGlassPointerExited;
    }

    private async Task InitializeWallpaperAsync()
    {
        if (_welcomePlayed) return;
        _welcomePlayed = true;
        await RefreshWallpaperLibraryAsync();
        PlayInterfaceSound("startup");
        PlayWelcome();
    }

    private static bool PreferenceEnabled(string name, bool fallback = false) =>
        AppPaths.GetPreference(name, fallback ? "true" : "false") == "true";

    private static double ReadSettingNumber(string name, double fallback, double minimum, double maximum) =>
        double.TryParse(AppPaths.GetPreference(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)
            && double.IsFinite(value) ? Math.Clamp(value, minimum, maximum) : fallback;

    private void ThemeMode_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_appearanceReady) return;
        SaveSetting("theme", ThemeMode.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" });
        ApplyTheme();
    }

    private void AppearanceToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (!_appearanceReady || sender is not ToggleSwitch toggle) return;
        var key = toggle.Name switch
        {
            nameof(InvertTheme) => "invertTheme", nameof(GlassEnabled) => "glass",
            nameof(ReduceMotion) => "reduceMotion", nameof(PerformanceMode) => "performanceMode",
            nameof(InterfaceSounds) => "interfaceSounds",
            nameof(CompleteDependencies) => "completeDependencies", _ => ""
        };
        if (key.Length == 0) return;
        SaveSetting(key, toggle.IsOn ? "true" : "false");
        if (key == "interfaceSounds" && !toggle.IsOn)
        {
            _interfacePlayer?.Pause();
            _interfacePlayer?.Dispose();
            _interfaceAudioStream?.Dispose();
            _interfacePlayer = null;
            _interfaceAudioStream = null;
        }
        ApplyTheme();
        UpdateWallpaperPlayback();
    }

    private void GlassMaterial_Changed(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (!_appearanceReady || _resettingGlass || sender is not Slider slider) return;
        var key = slider.Name switch
        {
            nameof(GlassTransparency) => "glassTransparency",
            nameof(GlassShadow) => "glassShadow",
            nameof(GlassBlur) => "glassBlur",
            nameof(SidebarGlassBlur) => "glassSidebarBlur",
            nameof(AccountListGlassBlur) => "glassAccountListBlur",
            nameof(AccountDetailsGlassBlur) => "glassAccountDetailsBlur",
            _ => ""
        };
        if (key.Length == 0) return;
        SaveSetting(key, ((int)e.NewValue).ToString(CultureInfo.InvariantCulture));
        if (ReferenceEquals(slider, GlassBlur)) UpdateInheritedGlassBlur();
        if (ReferenceEquals(slider, GlassShadow)) UpdateGlassShadowOpacity();
        else ApplyTheme();
    }

    private void UpdateInheritedGlassBlur()
    {
        _resettingGlass = true;
        try
        {
            foreach (var (slider, preference) in new[]
            {
                (SidebarGlassBlur, "glassSidebarBlur"),
                (AccountListGlassBlur, "glassAccountListBlur"),
                (AccountDetailsGlassBlur, "glassAccountDetailsBlur")
            })
                if (AppPaths.GetPreference(preference).Length == 0) slider.Value = GlassBlur.Value;
        }
        finally { _resettingGlass = false; }
    }

    private void ResetGlass_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            AppPaths.SetPreferences(
                ("glassTransparency", null), ("glassShadow", null), ("glassBlur", null),
                ("glassSidebarBlur", null), ("glassAccountListBlur", null), ("glassAccountDetailsBlur", null));
        }
        catch (Exception error)
        {
            ShowStatus("设置无法保存：" + error.Message, InfoBarSeverity.Error);
            return;
        }
        _resettingGlass = true;
        try
        {
            GlassTransparency.Value = DefaultGlassTransparency;
            GlassShadow.Value = DefaultGlassShadow;
            SidebarGlassBlur.Value = AccountListGlassBlur.Value = AccountDetailsGlassBlur.Value = GlassBlur.Value = DefaultGlassBlur;
        }
        finally { _resettingGlass = false; }
        ApplyTheme();
    }

    private void WallpaperTuning_Changed(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (!_appearanceReady) return;
        SaveSetting(ReferenceEquals(sender, WallpaperDimming) ? "wallpaperDimming" : "wallpaperSoftness",
            ((int)e.NewValue).ToString(CultureInfo.InvariantCulture));
        QueueBackdropRefresh();
    }

    private void WelcomeVoice_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_appearanceReady) SaveSetting("welcomeVoice", Math.Max(0, WelcomeVoice.SelectedIndex).ToString(CultureInfo.InvariantCulture));
    }

    private void WelcomeVolume_Changed(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (!_appearanceReady) return;
        SaveSetting("welcomeVolume", ((int)e.NewValue).ToString(CultureInfo.InvariantCulture));
        if (_voicePlayer is not null) _voicePlayer.Volume = e.NewValue / 100;
    }

    private void InterfaceVolume_Changed(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (!_appearanceReady) return;
        SaveSetting("interfaceVolume", ((int)e.NewValue).ToString(CultureInfo.InvariantCulture));
        if (_interfacePlayer is not null) _interfacePlayer.Volume = e.NewValue / 100;
    }

    private void DownloadSource_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_appearanceReady) SaveSetting("downloadSource", DownloadSource.SelectedIndex == 1 ? "official" : "auto");
    }

    private void GameMemory_Changed(NumberBox sender, NumberBoxValueChangedEventArgs e)
    {
        if (_appearanceReady && double.IsFinite(e.NewValue))
            SaveSetting("gameMemory", ((int)Math.Clamp(e.NewValue, 1024, 6144)).ToString(CultureInfo.InvariantCulture));
    }

    private void SaveSetting(string key, string value)
    {
        try { AppPaths.SetPreference(key, value); }
        catch (Exception error) { ShowStatus("设置无法保存：" + error.Message, InfoBarSeverity.Error); }
    }

    private void OnHighContrastChanged(AccessibilitySettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => { ApplyTheme(); UpdateWallpaperPlayback(); });

    private void OnColorsChanged(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => { ApplyTheme(); UpdateWallpaperPlayback(); });

    private void OnAppearanceActivated(object sender, WindowActivatedEventArgs args)
    {
        ApplyTheme();
        UpdateWallpaperPlayback();
        UpdateAccountSkinOptions();
    }

    private bool AllowsAmbientAnimation() => !ReduceMotion.IsOn && _uiSettings.AnimationsEnabled
        && !_accessibility.HighContrast && (!PerformanceMode.IsOn || _runningGameRunDirectory is null)
        && AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    private void ApplyTheme()
    {
        var systemBackground = _uiSettings.GetColorValue(UIColorType.Background);
        var dark = ThemeMode.SelectedIndex == 2 || (ThemeMode.SelectedIndex == 0
            && systemBackground.R + systemBackground.G + systemBackground.B < 384);
        if (InvertTheme.IsOn) dark = !dark;
        RootShell.RequestedTheme = ThemeMode.SelectedIndex == 0 && !InvertTheme.IsOn
            ? ElementTheme.Default : dark ? ElementTheme.Dark : ElementTheme.Light;
        var highContrast = _accessibility.HighContrast;
        _chromeHighContrast = highContrast;
        _glassLayerActive = GlassEnabled.IsOn && _uiSettings.AdvancedEffectsEnabled && !highContrast;
        _glassMotionActive = _glassLayerActive && _chromeActive && AllowsAmbientAnimation();
        ApplyHarborPalette(dark, highContrast, systemBackground);
        UpdateAccountSkinOptions();
        var closeColor = highContrast ? _uiSettings.GetColorValue(UIColorType.Foreground) : Color.FromArgb(255, 225, 105, 93);
        var minimizeColor = highContrast ? closeColor : Color.FromArgb(255, 244, 197, 54);
        var maximizeColor = highContrast ? closeColor : Color.FromArgb(255, 101, 190, 54);
        var glyphColor = new SolidColorBrush(highContrast ? systemBackground : Color.FromArgb(255, 55, 52, 44));
        ChromeCloseDot.Background = new SolidColorBrush(closeColor);
        ChromeMinimizeDot.Background = new SolidColorBrush(minimizeColor);
        ChromeMaximizeDot.Background = new SolidColorBrush(maximizeColor);
        ChromeCloseGlyph.Foreground = glyphColor;
        ChromeMinimizeGlyph.Foreground = glyphColor;
        ChromeMaximizeGlyph.Foreground = glyphColor;
        UpdateChromeGlyphs();
    }

    private void OnAppearanceWindowChanged(AppWindow sender, AppWindowChangedEventArgs args) =>
        DispatcherQueue.TryEnqueue(() => { UpdateWallpaperPlayback(); UpdateAccountSkinOptions(); });

    private void UpdateWallpaperPlayback()
    {
        if (_wallpaperPlayer is null) return;
        var animate = _chromeActive && !_wallpaperLibraryOpen && AllowsAmbientAnimation();
        if (_playingWallpaper == animate) return;
        _playingWallpaper = animate;
        if (animate) _wallpaperPlayer.Play();
        else _wallpaperPlayer.Pause();
    }

    private async Task RefreshWallpaperLibraryAsync(bool applyWallpaper = true)
    {
        try
        {
            _wallpapers = WallpaperLibrary.Read();
            _settingWallpaper = true;
            WallpaperSelector.ItemsSource = new[] { new WallpaperEntry("Harbor 渐变", "") }.Concat(_wallpapers).ToArray();
            WallpaperSelector.SelectedItem = _wallpapers.FirstOrDefault(item => item.FileName == AppPaths.GetPreference("wallpaper"))
                ?? ((WallpaperEntry[])WallpaperSelector.ItemsSource)[0];
            _settingWallpaper = false;
            if (applyWallpaper) await ApplyWallpaperAsync(WallpaperSelector.SelectedItem as WallpaperEntry);
        }
        catch (Exception error) { ShowStatus("壁纸库无法读取：" + error.Message, InfoBarSeverity.Warning); }
        finally { _settingWallpaper = false; }
    }

    private async void Wallpaper_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_appearanceReady || _settingWallpaper) return;
        var entry = WallpaperSelector.SelectedItem as WallpaperEntry;
        SaveSetting("wallpaper", entry?.FileName ?? "");
        await ApplyWallpaperAsync(entry);
    }

    private async Task ApplyWallpaperAsync(WallpaperEntry? entry)
    {
        StopWallpaper();
        var request = _wallpaperRequest;
        if (entry is null || entry.FileName.Length == 0) return;
        try
        {
            var path = WallpaperLibrary.FilePath(entry);
            var file = await global::Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            if (request != _wallpaperRequest) return;
            if (entry.Video)
            {
                var player = new MediaPlayer
                {
                    IsMuted = true,
                    IsLoopingEnabled = true,
                    IsVideoFrameServerEnabled = true
                };
                _wallpaperPlayer = player;
                player.MediaFailed += (_, _) => DispatcherQueue.TryEnqueue(() =>
                {
                    if (_wallpaperPlayer != player) return;
                    StopWallpaper();
                    ShowStatus("无法解码这段视频。请尝试 MP4 / H.264。", InfoBarSeverity.Warning);
                });
                player.VideoFrameAvailable += WallpaperVideoFrameAvailable;
                player.MediaOpened += (_, _) => DispatcherQueue.TryEnqueue(() => WallpaperVideoOpened(player));
                player.PlaybackSession.NaturalVideoSizeChanged += (_, _) =>
                    DispatcherQueue.TryEnqueue(() => InitializeWallpaperFrameSurface(player));
                player.Source = MediaSource.CreateFromStorageFile(file);
                UpdateWallpaperPlayback();
            }
            else
            {
                var image = await LoadWallpaperCanvasBitmapAsync(file);
                if (request != _wallpaperRequest)
                {
                    image.Dispose();
                    return;
                }
                _wallpaperStillBitmap = image;
                QueueBackdropRefresh();
            }
        }
        catch (Exception error)
        {
            if (request != _wallpaperRequest) return;
            StopWallpaper();
            ShowStatus("壁纸无法显示：" + error.Message, InfoBarSeverity.Warning);
        }
    }

    private void StopWallpaper()
    {
        _wallpaperRequest++;
        var player = _wallpaperPlayer;
        _wallpaperPlayer = null;
        _playingWallpaper = false;
        if (player is not null)
        {
            player.VideoFrameAvailable -= WallpaperVideoFrameAvailable;
            player.Dispose();
        }
        _wallpaperFrameBitmap?.Dispose();
        _wallpaperFrameBitmap = null;
        _wallpaperFrameReady = false;
        _wallpaperStillBitmap?.Dispose();
        _wallpaperStillBitmap = null;
        QueueBackdropRefresh();
    }

    private async Task<CanvasBitmap> LoadWallpaperCanvasBitmapAsync(global::Windows.Storage.StorageFile file)
    {
        _wallpaperCanvasDevice ??= CanvasDevice.GetSharedDevice();
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var scale = Math.Min(1d, 1920d / Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
        var transform = new BitmapTransform
        {
            ScaledWidth = (uint)Math.Max(1, Math.Round(decoder.PixelWidth * scale)),
            ScaledHeight = (uint)Math.Max(1, Math.Round(decoder.PixelHeight * scale))
        };
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.ColorManageToSRgb);
        return CanvasBitmap.CreateFromSoftwareBitmap(_wallpaperCanvasDevice, bitmap);
    }

    private void WallpaperVideoOpened(MediaPlayer player)
    {
        InitializeWallpaperFrameSurface(player);
        if (!ReferenceEquals(_wallpaperPlayer, player) || _playingWallpaper || _wallpaperFrameReady) return;
        try { player.StepForwardOneFrame(); }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
    }

    private void InitializeWallpaperFrameSurface(MediaPlayer player)
    {
        if (!ReferenceEquals(_wallpaperPlayer, player)) return;
        var naturalWidth = (int)player.PlaybackSession.NaturalVideoWidth;
        var naturalHeight = (int)player.PlaybackSession.NaturalVideoHeight;
        if (naturalWidth <= 0 || naturalHeight <= 0) return;

        var resize = Math.Min(1d, Math.Min(1920d / naturalWidth, 1080d / naturalHeight));
        var width = Math.Max(1, (int)Math.Round(naturalWidth * resize));
        var height = Math.Max(1, (int)Math.Round(naturalHeight * resize));
        try
        {
            if (_wallpaperFrameBitmap?.SizeInPixels.Width == width
                && _wallpaperFrameBitmap.SizeInPixels.Height == height) return;
            _wallpaperCanvasDevice ??= CanvasDevice.GetSharedDevice();
            _wallpaperFrameBitmap?.Dispose();
            _wallpaperFrameBitmap = new CanvasRenderTarget(_wallpaperCanvasDevice, width, height, 96);
            _wallpaperFrameReady = false;
        }
        catch (Exception error) when (error is InvalidOperationException or NotSupportedException
            or System.Runtime.InteropServices.COMException)
        {
            StopWallpaper();
            ShowStatus("视频壁纸渲染器无法初始化：" + error.Message, InfoBarSeverity.Warning);
        }
    }

    private void WallpaperVideoFrameAvailable(MediaPlayer sender, object args)
    {
        if (!ReferenceEquals(_wallpaperPlayer, sender) || (!_playingWallpaper && _wallpaperFrameReady)) return;
        var now = Stopwatch.GetTimestamp();
        var previous = Interlocked.Read(ref _lastWallpaperFrameTimestamp);
        if (now - previous < Stopwatch.Frequency / 24
            || Interlocked.Exchange(ref _wallpaperFrameQueued, 1) != 0) return;
        Interlocked.Exchange(ref _lastWallpaperFrameTimestamp, now);

        if (!DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            try
            {
                if (!ReferenceEquals(_wallpaperPlayer, sender) || (!_playingWallpaper && _wallpaperFrameReady)) return;
                if (_wallpaperFrameBitmap is null)
                    InitializeWallpaperFrameSurface(sender);
                if (_wallpaperFrameBitmap is null) return;

                sender.CopyFrameToVideoSurface(_wallpaperFrameBitmap,
                    new Rect(0, 0, _wallpaperFrameBitmap.SizeInPixels.Width, _wallpaperFrameBitmap.SizeInPixels.Height));
                _wallpaperFrameReady = true;
                DrawBackdrop();
            }
            catch (Exception error) when (error is InvalidOperationException or NotSupportedException
                or System.Runtime.InteropServices.COMException)
            {
                if (ReferenceEquals(_wallpaperPlayer, sender))
                {
                    StopWallpaper();
                    ShowStatus("视频壁纸帧处理失败：" + error.Message, InfoBarSeverity.Warning);
                }
            }
            finally
            {
                Interlocked.Exchange(ref _wallpaperFrameQueued, 0);
            }
        }))
        {
            Interlocked.Exchange(ref _wallpaperFrameQueued, 0);
        }
    }

    private async void ImportWallpaper_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var file = await PickFileAsync(".png", ".jpg", ".jpeg", ".bmp", ".mp4");
            if (file is null) return;
            var extension = Path.GetExtension(file.Name).ToLowerInvariant();
            if (extension is not (".png" or ".jpg" or ".jpeg" or ".bmp" or ".mp4"))
                throw new IOException("请选择图片或 MP4。");
            var name = new TextBox { Header = "壁纸名称", Text = Path.GetFileNameWithoutExtension(file.Name), MaxLength = 80 };
            if (await FriendDialog("导入壁纸", name, "导入").ShowAsync() != ContentDialogResult.Primary) return;
            var label = name.Text.Trim();
            if (label.Length == 0) throw new IOException("请输入壁纸名称。");
            var entry = await WallpaperLibrary.ImportAsync(file.Path, label);
            SaveSetting("wallpaper", entry.FileName);
            await RefreshWallpaperLibraryAsync();
        }
        catch (Exception error) { ShowStatus("壁纸导入失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private async void RemoveWallpaper_Click(object sender, RoutedEventArgs e)
    {
        if (WallpaperSelector.SelectedItem is not WallpaperEntry { FileName.Length: > 0 } entry) return;
        try
        {
            var dialog = FriendDialog("移除壁纸", new TextBlock { Text = $"从启动器壁纸库移除 {entry.Name}？" }, "移除");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            await RemoveLibraryWallpaperAsync(entry);
        }
        catch (Exception error) { ShowStatus("壁纸移除失败：" + error.Message, InfoBarSeverity.Error); }
    }

    private void PreviewWelcome_Click(object sender, RoutedEventArgs e) => PlayWelcome();

    private void PlayWelcome()
    {
        var name = WelcomeVoice.SelectedIndex switch
        {
            1 => "welcome.mp3", 2 => "welcome-female2.mp3",
            3 => "welcome-male.mp3", 4 => "welcome-male2.mp3", _ => ""
        };
        if (name.Length == 0) return;
        try
        {
            var path = Path.Combine(AppPaths.ApplicationDirectory, "Assets", "Voice", name);
            if (!File.Exists(path)) return;
            _voicePlayer ??= new MediaPlayer();
            _voicePlayer.Volume = WelcomeVolume.Value / 100;
            _voicePlayer.Source = MediaSource.CreateFromUri(new Uri(path));
            _voicePlayer.Play();
        }
        catch (Exception error) { ShowStatus("无法播放欢迎语音：" + error.Message, InfoBarSeverity.Warning); }
    }

    private async void OpenApplicationData_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDirectory);
            var folder = await global::Windows.Storage.StorageFolder.GetFolderFromPathAsync(AppPaths.DataDirectory);
            await global::Windows.System.Launcher.LaunchFolderAsync(folder);
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private async void RunDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            ShowStatus("正在检查版本下载源…", InfoBarSeverity.Informational);
            var result = await RequireBridge().InvokeAsync("diagnostics");
            ShowStatus(result["report"]?.GetValue<string>() ?? "诊断完成。", InfoBarSeverity.Informational);
        }
        catch (Exception error) { ShowStatus(error.Message, InfoBarSeverity.Error); }
    }

    private void OnAppearanceClosed(object sender, WindowEventArgs args)
    {
        _appearanceWindowLoaded = false;
        if (_contrastEventsAttached) _accessibility.HighContrastChanged -= OnHighContrastChanged;
        if (_colorEventsAttached) _uiSettings.ColorValuesChanged -= OnColorsChanged;
        Activated -= OnAppearanceActivated;
        Activated -= WindowChrome_Activated;
        AppWindow.Changed -= OnAppearanceWindowChanged;
        AppWindow.Changed -= WindowChrome_Changed;
        _windowFrame?.Dispose();
        RootShell.Tag = null;
        CancelAccountSkinPreview();
        StopWallpaper();
        ReleaseBackdrop();
        _voicePlayer?.Dispose();
        _interfacePlayer?.Dispose();
        _interfaceAudioStream?.Dispose();
        _interfacePlayer = null;
        _interfaceAudioStream = null;
    }

    private void OnGlassPointerMoved(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args)
    {
        var target = FindInteractiveSoundTarget(args.OriginalSource as DependencyObject);
        if (!ReferenceEquals(target, _lastHoverSoundTarget))
        {
            _lastHoverSoundTarget = target;
            var now = DateTimeOffset.UtcNow;
            if (target is not null && _appearanceWindowLoaded && now - _lastFocusSound > TimeSpan.FromMilliseconds(90))
            {
                _lastFocusSound = now;
                PlayInterfaceSound("focus");
            }
        }
    }

    private void OnGlassPointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args)
    {
        if (_appearanceWindowLoaded && FindInteractiveSoundTarget(args.OriginalSource as DependencyObject) is { } target
            && target is UIElement element && !SidebarItems.Children.Contains(element))
            PlayInterfaceSound("select");
    }

    private void OnGlassPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args) =>
        _lastHoverSoundTarget = null;

    private void OnGlassKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args)
    {
        if (!_appearanceWindowLoaded || args.Key is not (global::Windows.System.VirtualKey.Enter or global::Windows.System.VirtualKey.Space)) return;
        if (FindInteractiveSoundTarget(args.OriginalSource as DependencyObject) is { } target
            && target is UIElement element && !SidebarItems.Children.Contains(element))
            PlayInterfaceSound("select");
    }

    private static DependencyObject? FindInteractiveSoundTarget(DependencyObject? source)
    {
        for (var current = source; current is not null; current = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(current))
            if (current is ButtonBase or ComboBox or Slider or NumberBox or ListViewItem or GridViewItem)
                return current;
        return null;
    }

    private async void PlayInterfaceSound(string cue)
    {
        if (!_appearanceReady || !_appearanceWindowLoaded || !InterfaceSounds.IsOn || InterfaceVolume.Value <= 0) return;
        _interfaceSoundbank ??= InterfaceSoundbank.TryLoad(Path.Combine(AppPaths.ApplicationDirectory, "Assets", "Audio", "Interface.soundbank"));
        var bytes = _interfaceSoundbank?.GetCue(cue);
        if (bytes is null) return;

        try
        {
            _interfacePlayer?.Pause();
            _interfacePlayer?.Dispose();
            _interfaceAudioStream?.Dispose();
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            var player = new MediaPlayer { Volume = InterfaceVolume.Value / 100 };
            _interfaceAudioStream = stream;
            _interfacePlayer = player;
            player.MediaEnded += (_, _) => DispatcherQueue.TryEnqueue(() => ReleaseInterfacePlayer(player, stream));
            player.MediaFailed += (_, _) => DispatcherQueue.TryEnqueue(() => ReleaseInterfacePlayer(player, stream));
            player.Source = MediaSource.CreateFromStream(stream, "audio/mpeg");
            player.Play();
        }
        catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            _interfacePlayer?.Dispose();
            _interfaceAudioStream?.Dispose();
            _interfacePlayer = null;
            _interfaceAudioStream = null;
        }
    }

    private void ReleaseInterfacePlayer(MediaPlayer player, InMemoryRandomAccessStream stream)
    {
        if (!ReferenceEquals(_interfacePlayer, player)) return;
        player.Dispose();
        stream.Dispose();
        _interfacePlayer = null;
        _interfaceAudioStream = null;
    }
}
