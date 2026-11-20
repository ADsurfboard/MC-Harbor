using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MCHarbor.Windows.Controls;
using MCHarbor.Windows.Services;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private readonly Dictionary<HarborGlassCard, GlassCardSurface?> _glassCards = [];
    private readonly Dictionary<ScrollViewer, int> _glassScrollViewers = [];
    private readonly HashSet<ScrollViewer> _scrollingGlassViewers = [];
    private readonly Dictionary<double, GlassWallpaperBlur> _blurredWallpaper = [];
    private HarborBackdrop? _harborBackdrop;
    private CanvasImageSource? _windowGlassImage;
    private readonly ImageBrush _windowGlassBrush = new() { Stretch = Stretch.Fill };
    private readonly SolidColorBrush _glassBorder = new();
    private readonly SolidColorBrush _windowTint = new();
    private readonly SolidColorBrush _cardFallback = new();
    private readonly SolidColorBrush _scrollingGlassFill = new();
    private bool _backdropQueued;
    private bool _wallpaperDirty;
    private bool _glassDirty;
    private long _lastGlassTimestamp;
    private long _glassRevision;
    private Color _backdropStart;
    private Color _backdropEnd;
    private Color _backdropGlow;
    private Color _cardTint;
    private bool _darkAppearance;
    private double _glassClarity;
    private double _blurBlend;
    private double _cardShadowOpacity;

    private void ApplyHarborPalette(bool dark, bool highContrast, Color systemBackground)
    {
        var start = dark ? Color.FromArgb(255, 26, 26, 26) : Color.FromArgb(255, 240, 240, 240);
        var end = dark ? Color.FromArgb(255, 55, 55, 55) : Color.FromArgb(255, 213, 213, 213);
        var glow = dark ? Color.FromArgb(46, 151, 151, 151) : Color.FromArgb(56, 255, 255, 255);
        var paletteChanged = start != _backdropStart || end != _backdropEnd;
        _backdropStart = start;
        _backdropEnd = end;
        _backdropGlow = glow;
        _darkAppearance = dark;
        _glassClarity = GlassTransparency.Value / 100;
        _blurBlend = 0.94 - 0.74 * _glassClarity;

        var background = highContrast ? systemBackground : start;
        var foreground = _uiSettings.GetColorValue(UIColorType.Foreground);
        ((SolidColorBrush)RootShell.Background).Color = background;
        WallpaperImage.Opacity = highContrast ? 0 : 1;
        WindowGlassTint.Background = _windowTint;
        _windowTint.Color = _glassLayerActive ? WithAlpha(start, (byte)Math.Round(94 - 86 * _glassClarity))
            : Microsoft.UI.Colors.Transparent;
        _cardTint = WithAlpha(dark ? Color.FromArgb(255, 46, 46, 46) : Color.FromArgb(255, 245, 245, 245),
            (byte)Math.Round((dark ? 145 : 158) - 122 * _glassClarity));
        _scrollingGlassFill.Color = _cardTint;
        _cardFallback.Color = highContrast ? systemBackground
            : dark ? Color.FromArgb(255, 43, 43, 43) : Color.FromArgb(255, 241, 241, 241);
        _glassBorder.Color = highContrast ? foreground
            : dark ? Color.FromArgb(59, 240, 240, 240) : Color.FromArgb(45, 45, 45, 45);
        ((SolidColorBrush)RootShell.Resources["HarborPanelStroke"]).Color = _glassBorder.Color;
        SidebarDivider.Background = new SolidColorBrush(highContrast ? foreground
            : dark ? Color.FromArgb(39, 248, 248, 248) : Color.FromArgb(32, 42, 42, 42));
        UpdateGlassShadowOpacity();
        ApplyButtonPalette(dark, highContrast, systemBackground, foreground);
        UpdateSkinOptionButtons();
        UpdateNavigationSelection();
        UpdatePageSelections();
        UpdateFeaturedGameWidth();
        UpdateFeaturedLaunch();

        if (paletteChanged || _harborBackdrop?.Surface is null) QueueBackdropRefresh();
        else QueueGlassMaterialRefresh();
    }

    private static Color WithAlpha(Color color, byte alpha) => Color.FromArgb(alpha, color.R, color.G, color.B);

    private void ApplyButtonPalette(bool dark, bool highContrast, Color systemBackground, Color foreground)
    {
        var resources = RootShell.Resources;
        var glass = (AcrylicBrush)resources["HarborButtonGlass"];
        var prominent = (AcrylicBrush)resources["HarborProminentGlass"];
        var buttonTint = dark ? Color.FromArgb(255, 49, 49, 49) : Color.FromArgb(255, 240, 240, 240);
        var accentTint = dark ? Color.FromArgb(255, 187, 221, 216) : Color.FromArgb(255, 176, 213, 210);
        glass.TintColor = buttonTint;
        glass.TintOpacity = 0.79 - 0.18 * _glassClarity;
        glass.FallbackColor = highContrast ? systemBackground
            : dark ? Color.FromArgb(255, 60, 60, 60) : Color.FromArgb(255, 234, 234, 234);
        prominent.TintColor = accentTint;
        prominent.TintOpacity = 0.85 - 0.20 * _glassClarity;
        prominent.FallbackColor = highContrast ? systemBackground : accentTint;
        glass.AlwaysUseFallback = prominent.AlwaysUseFallback = !_glassLayerActive;
        ((SolidColorBrush)resources["HarborProminentText"]).Color = highContrast ? foreground : Color.FromArgb(255, 20, 37, 38);
        ((LinearGradientBrush)resources["HarborButtonShine"]).Opacity = _glassLayerActive ? 1 : 0;
        var rim = (LinearGradientBrush)resources["HarborButtonRim"];
        rim.GradientStops[0].Color = highContrast ? foreground : Color.FromArgb(98, 255, 255, 255);
        rim.GradientStops[1].Color = highContrast ? foreground
            : dark ? Color.FromArgb(37, 255, 255, 255) : Color.FromArgb(36, 48, 48, 48);
        rim.GradientStops[2].Color = highContrast ? foreground : Color.FromArgb(56, 0, 0, 0);
    }

    private void UpdateGlassShadowOpacity()
    {
        var strength = _glassLayerActive ? GlassShadow.Value / 100 : 0;
        _cardShadowOpacity = strength * 0.54;
        ((SolidColorBrush)RootShell.Resources["HarborButtonShadowCore"]).Opacity = strength;
        ((LinearGradientBrush)RootShell.Resources["HarborButtonShadowSoft"]).Opacity = strength;
        foreach (var card in _glassCards.Keys)
            if (card.IsInViewport && IsVisibleOnPage(card)) card.ApplyShadow(_cardShadowOpacity);
    }

    private void QueueBackdropRefresh()
    {
        _wallpaperDirty = true;
        QueueVisualRefresh();
    }

    private void QueueGlassMaterialRefresh()
    {
        _glassDirty = true;
        QueueVisualRefresh();
    }

    private void QueueGlassCardsRefresh() => QueueVisualRefresh();

    private void QueueVisualRefresh()
    {
        if (!_appearanceWindowLoaded || _backdropQueued) return;
        _backdropQueued = DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _backdropQueued = false;
            if (!_appearanceWindowLoaded) return;
            var repaintWallpaper = _wallpaperDirty;
            var repaintGlass = _glassDirty;
            _wallpaperDirty = _glassDirty = false;
            if (repaintWallpaper || _harborBackdrop?.Surface is null)
                DrawBackdrop(forceGlass: true);
            else if (repaintGlass)
                DrawGlass(_harborBackdrop.Surface, new Size(RootShell.ActualWidth, RootShell.ActualHeight));
            else
                RefreshGlassCards(_harborBackdrop.Surface, new Size(RootShell.ActualWidth, RootShell.ActualHeight));
        });
    }

    internal void RegisterGlassCard(HarborGlassCard card)
    {
        if (!_glassCards.TryAdd(card, null)) return;
        card.GlassInvalidated += GlassCard_Invalidated;
        foreach (var scroll in card.ScrollAncestors)
        {
            var count = _glassScrollViewers.GetValueOrDefault(scroll);
            _glassScrollViewers[scroll] = count + 1;
            if (count != 0) continue;
            scroll.ViewChanging += GlassScroll_ViewChanging;
            scroll.ViewChanged += GlassScroll_ViewChanged;
        }
        if (_glassLayerActive && UsesWindowGlass(card)) ApplyWindowGlass(card);
        else card.ApplyMaterial(_cardFallback, _glassBorder, _cardShadowOpacity, interactive: false);
        QueueGlassCardsRefresh();
    }

    internal void UnregisterGlassCard(HarborGlassCard card)
    {
        card.GlassInvalidated -= GlassCard_Invalidated;
        if (!_glassCards.Remove(card, out var surface)) return;
        surface?.Dispose();
        foreach (var scroll in card.ScrollAncestors)
        {
            var remaining = _glassScrollViewers[scroll] - 1;
            if (remaining > 0)
            {
                _glassScrollViewers[scroll] = remaining;
                continue;
            }
            _glassScrollViewers.Remove(scroll);
            _scrollingGlassViewers.Remove(scroll);
            scroll.ViewChanging -= GlassScroll_ViewChanging;
            scroll.ViewChanged -= GlassScroll_ViewChanged;
        }
    }

    private void GlassCard_Invalidated(object? sender, EventArgs e) => QueueGlassCardsRefresh();

    private void GlassScroll_ViewChanging(object? sender, ScrollViewerViewChangingEventArgs e)
    {
        if (sender is ScrollViewer scroll) BeginGlassScroll(scroll);
    }

    private void GlassScroll_ViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (sender is not ScrollViewer scroll) return;
        if (e.IsIntermediate) BeginGlassScroll(scroll);
        else
        {
            _scrollingGlassViewers.Remove(scroll);
            QueueGlassCardsRefresh();
        }
    }

    private void BeginGlassScroll(ScrollViewer scroll)
    {
        if (!_scrollingGlassViewers.Add(scroll) || !_glassLayerActive) return;
        foreach (var card in _glassCards.Keys)
        {
            if (card.HasSurface && card.IsInViewport && card.ScrollAncestors.Contains(scroll) && IsVisibleOnPage(card))
                ApplyWindowGlass(card);
        }
    }

    private bool UsesWindowGlass(HarborGlassCard card) =>
        card.IsClippedByViewport || card.ScrollAncestors.Any(_scrollingGlassViewers.Contains);

    private void ApplyWindowGlass(HarborGlassCard card)
    {
        // The window already draws its blurred wallpaper in place. Reuse it as the viewport moves.
        card.ApplyMaterial(_scrollingGlassFill, _glassBorder, _cardShadowOpacity, interactive: false, glassEnabled: true);
    }

    private void DrawBackdrop(bool forceGlass = false)
    {
        if (!_appearanceWindowLoaded || _chromeHighContrast)
        {
            ApplyCardFallback();
            return;
        }
        var viewport = new Size(RootShell.ActualWidth, RootShell.ActualHeight);
        if (viewport.Width < 1 || viewport.Height < 1) return;
        try
        {
            _wallpaperCanvasDevice ??= CanvasDevice.GetSharedDevice();
            _harborBackdrop ??= new HarborBackdrop(_wallpaperCanvasDevice);
            ICanvasImage? media = _wallpaperFrameReady ? _wallpaperFrameBitmap : _wallpaperStillBitmap;
            _harborBackdrop.Draw(viewport, _backdropStart, _backdropEnd, _backdropGlow, media,
                WallpaperDimming.Value / 100, WallpaperSoftness.Value);
            if (!ReferenceEquals(WallpaperImage.Source, _harborBackdrop.ImageSource))
                WallpaperImage.Source = _harborBackdrop.ImageSource;

            var now = Stopwatch.GetTimestamp();
            if (forceGlass || now - _lastGlassTimestamp >= Stopwatch.Frequency / 12)
                DrawGlass(_harborBackdrop.Surface!, viewport);
        }
        catch (Exception error) when (IsGlassDrawingError(error))
        {
            ReleaseBackdrop();
        }
    }

    private void DrawGlass(CanvasRenderTarget source, Size viewport)
    {
        if (!CanDrawGlass(viewport))
        {
            ApplyCardFallback();
            return;
        }
        try
        {
            _lastGlassTimestamp = Stopwatch.GetTimestamp();
            _glassRevision++;
            var radii = new[] { GlassBlur.Value, SidebarGlassBlur.Value, AccountListGlassBlur.Value, AccountDetailsGlassBlur.Value };
            foreach (var oldRadius in _blurredWallpaper.Keys.Except(radii).ToArray())
            {
                _blurredWallpaper[oldRadius].Dispose();
                _blurredWallpaper.Remove(oldRadius);
            }
            var blurred = GetBlurredWallpaper(source, viewport, GlassBlur.Value);
            if (GlassBlur.Value == 0 && SidebarGlassBlur.Value == 0)
            {
                WindowGlassLayer.Background = null;
            }
            else
            {
                var width = blurred.SizeInPixels.Width;
                var height = blurred.SizeInPixels.Height;
                if (_windowGlassImage?.SizeInPixels.Width != width || _windowGlassImage.SizeInPixels.Height != height)
                {
                    _windowGlassImage = new CanvasImageSource(_wallpaperCanvasDevice!, width, height, 96);
                    _windowGlassBrush.ImageSource = _windowGlassImage;
                }
                using (var drawing = _windowGlassImage.CreateDrawingSession(_backdropStart))
                {
                    drawing.DrawImage(blurred);
                    if (SidebarGlassBlur.Value != GlassBlur.Value)
                    {
                        var sidebarBlur = GetBlurredWallpaper(source, viewport, SidebarGlassBlur.Value);
                        var sidebarWidth = Math.Clamp(Math.Round(Sidebar.ActualWidth * width / viewport.Width), 0, width);
                        if (sidebarWidth > 0)
                        {
                            var strip = new Rect(0, 0, sidebarWidth, height);
                            drawing.DrawImage(sidebarBlur, strip, strip);
                        }
                    }
                }
                _windowGlassBrush.Opacity = _blurBlend * 0.60;
                if (!ReferenceEquals(WindowGlassLayer.Background, _windowGlassBrush))
                    WindowGlassLayer.Background = _windowGlassBrush;
            }
            RefreshGlassCards(source, viewport);
        }
        catch (Exception error) when (IsGlassDrawingError(error))
        {
            ApplyCardFallback();
        }
    }

    private bool CanDrawGlass(Size viewport) => _appearanceWindowLoaded && _glassLayerActive && !_chromeHighContrast
        && viewport.Width >= 1 && viewport.Height >= 1;

    private CanvasRenderTarget GetBlurredWallpaper(CanvasRenderTarget source, Size viewport, double radius)
    {
        if (radius <= 0) return source;
        if (!_blurredWallpaper.TryGetValue(radius, out var blur))
            _blurredWallpaper.Add(radius, blur = new GlassWallpaperBlur(_wallpaperCanvasDevice!));
        return blur.GetSurface(source, viewport, radius, _glassRevision);
    }

    private void RefreshGlassCards(CanvasRenderTarget source, Size viewport)
    {
        if (!CanDrawGlass(viewport))
        {
            ApplyCardFallback();
            return;
        }
        var device = _wallpaperCanvasDevice!;
        foreach (var (card, previous) in _glassCards.ToArray())
        {
            if (!card.HasSurface || !IsVisibleOnPage(card))
            {
                if (previous is not null) ClearGlassCard(card, previous);
                continue;
            }
            if (!card.IsInViewport) continue;
            if (UsesWindowGlass(card))
            {
                ApplyWindowGlass(card);
                continue;
            }
            var bounds = BoundsInWindow(card);
            if (bounds.Width < 1 || bounds.Height < 1 || bounds.Right <= 0 || bounds.Bottom <= 0
                || bounds.Left >= viewport.Width || bounds.Top >= viewport.Height) continue;

            try
            {
                var radius = card.BlurGroup switch
                {
                    HarborGlassBlurGroup.AccountList => AccountListGlassBlur.Value,
                    HarborGlassBlurGroup.AccountDetails => AccountDetailsGlassBlur.Value,
                    _ => GlassBlur.Value
                };
                var blurred = GetBlurredWallpaper(source, viewport, radius);
                var surface = previous ?? new GlassCardSurface(device);
                if (previous is null) _glassCards[card] = surface;
                var edgeOpacity = 0.22 + 0.65 * _glassClarity;
                var fill = surface.Draw(source, blurred, viewport, bounds, card.CornerRadius.TopLeft,
                    _glassMotionActive ? card.EdgeAmount : 8, _backdropStart, _cardTint,
                    _blurBlend, edgeOpacity, _glassRevision);
                card.ApplyMaterial(fill, _glassBorder, _cardShadowOpacity, _glassMotionActive, glassEnabled: true);
            }
            catch (Exception error) when (IsGlassDrawingError(error))
            {
                card.ApplyMaterial(_cardFallback, _glassBorder, _cardShadowOpacity, interactive: false);
            }
        }
    }

    private bool IsVisibleOnPage(FrameworkElement element)
    {
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: Visibility.Collapsed }) return false;
            if (ReferenceEquals(current, RootShell)) return true;
        }
        return false;
    }

    private Rect BoundsInWindow(FrameworkElement element)
    {
        if (element.XamlRoot is null || element.ActualWidth < 1 || element.ActualHeight < 1) return Rect.Empty;
        return element.TransformToVisual(RootShell)
            .TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
    }

    private static bool IsGlassDrawingError(Exception error) => error is InvalidOperationException
        or NotSupportedException or System.Runtime.InteropServices.COMException or ArgumentException or OutOfMemoryException;

    private void ApplyCardFallback()
    {
        WindowGlassLayer.Background = null;
        foreach (var card in _glassCards.Keys)
            card.ApplyMaterial(_cardFallback, _glassBorder, _cardShadowOpacity, interactive: false);
    }

    private void ClearGlassCard(HarborGlassCard card, GlassCardSurface surface)
    {
        card.ApplyMaterial(_cardFallback, _glassBorder, 0, interactive: false);
        surface.Dispose();
        _glassCards[card] = null;
    }

    private void ReleaseBackdrop()
    {
        ApplyCardFallback();
        WallpaperImage.Source = null;
        _harborBackdrop?.Dispose();
        _harborBackdrop = null;
        _windowGlassBrush.ImageSource = null;
        _windowGlassImage = null;
        foreach (var blur in _blurredWallpaper.Values) blur.Dispose();
        _blurredWallpaper.Clear();
        foreach (var (card, surface) in _glassCards.ToArray())
        {
            if (surface is not null) ClearGlassCard(card, surface);
        }
    }
}
