using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace MCHarbor.Windows.Controls;

public enum HarborGlassBlurGroup { Default, AccountList, AccountDetails }

public sealed class HarborGlassCard : ContentControl
{
    private const int ShadowPadding = 24;
    private static readonly Dictionary<int, WriteableBitmap> ShadowImages = [];
    private Border? _surface;
    private Image? _shadow;
    private Border? _film;
    private Border? _highlight;
    private RadialGradientBrush? _highlightBrush;
    private MainWindow? _host;
    private bool _interactive;
    private Rect? _effectiveViewport;

    public HarborGlassCard()
    {
        SizeChanged += (_, _) => InvalidateGlass();
        Loaded += (_, _) =>
        {
            _host = FindGlassHost();
            _host?.RegisterGlassCard(this);
        };
        EffectiveViewportChanged += (_, args) =>
        {
            _effectiveViewport = args.EffectiveViewport;
            InvalidateGlass();
        };
        Unloaded += (_, _) =>
        {
            _effectiveViewport = null;
            _host?.UnregisterGlassCard(this);
            _host = null;
            ScrollAncestors = [];
        };
        PointerEntered += (_, args) => UpdateHighlight(args, 14);
        PointerMoved += (_, args) => UpdateHighlight(args, EdgeAmount);
        PointerExited += (_, _) => SetHighlight(new Point(0.28, 0.12), 8);
        AddHandler(PointerPressedEvent, new PointerEventHandler(OnPointerPressed), true);
        AddHandler(PointerReleasedEvent, new PointerEventHandler(OnPointerReleased), true);
        PointerCanceled += (_, _) => SetHighlight(new Point(0.28, 0.12), 8);
    }

    public HarborGlassBlurGroup BlurGroup { get; set; }
    internal float EdgeAmount { get; private set; } = 8;
    internal bool HasSurface => _surface is not null;
    internal bool IsInViewport => _effectiveViewport is not { } viewport
        || (viewport.Width > 0 && viewport.Height > 0 && viewport.Right > 0 && viewport.Bottom > 0
            && viewport.Left < ActualWidth && viewport.Top < ActualHeight);
    internal bool IsClippedByViewport => ScrollAncestors.Length > 0 && _effectiveViewport is { } viewport
        && (viewport.Left > 1 || viewport.Top > 1 || viewport.Right < ActualWidth - 1 || viewport.Bottom < ActualHeight - 1);
    internal ScrollViewer[] ScrollAncestors { get; private set; } = [];
    internal event EventHandler? GlassInvalidated;

    private MainWindow? FindGlassHost()
    {
        var scrollAncestors = new List<ScrollViewer>();
        for (DependencyObject? current = this; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is ScrollViewer scroll) scrollAncestors.Add(scroll);
            if (current is Grid { Tag: MainWindow window })
            {
                ScrollAncestors = scrollAncestors.ToArray();
                return window;
            }
        }
        return null;
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        _surface = GetTemplateChild("Surface") as Border;
        _shadow = GetTemplateChild("ShadowImage") as Image;
        _film = GetTemplateChild("Film") as Border;
        _highlight = GetTemplateChild("Highlight") as Border;
        _highlightBrush = _highlight?.Background as RadialGradientBrush;
        InvalidateGlass();
    }

    internal void ApplyMaterial(Brush fill, Brush edge, double shadowOpacity, bool interactive, bool glassEnabled = false)
    {
        if (_surface is not null && !ReferenceEquals(_surface.Background, fill)) _surface.Background = fill;
        if (!ReferenceEquals(BorderBrush, edge)) BorderBrush = edge;
        if (_film is not null)
            _film.Visibility = glassEnabled ? Visibility.Visible : Visibility.Collapsed;
        _interactive = interactive;
        if (!interactive && EdgeAmount != 8) SetHighlight(new Point(0.28, 0.12), 8);
        if (_highlight is not null)
            _highlight.Visibility = interactive ? Visibility.Visible : Visibility.Collapsed;
        ApplyShadow(shadowOpacity);
    }

    internal void ApplyShadow(double shadowOpacity)
    {
        if (_shadow is null) return;
        _shadow.Opacity = shadowOpacity;
        if (shadowOpacity <= 0) return;

        var radius = (int)Math.Round(Math.Clamp(CornerRadius.TopLeft, 1, 32));
        if (!ShadowImages.TryGetValue(radius, out var image))
            ShadowImages[radius] = image = CreateShadowImage(radius);
        if (!ReferenceEquals(_shadow.Source, image))
        {
            _shadow.NineGrid = new Thickness(ShadowPadding + radius);
            _shadow.Source = image;
        }
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs args) => UpdateHighlight(args, 19);
    private void OnPointerReleased(object sender, PointerRoutedEventArgs args) => UpdateHighlight(args, 14);

    private void UpdateHighlight(PointerRoutedEventArgs args, float amount)
    {
        if (!_interactive || ActualWidth <= 0 || ActualHeight <= 0) return;
        var p = args.GetCurrentPoint(this).Position;
        if (p.X < 0 || p.Y < 0 || p.X > ActualWidth || p.Y > ActualHeight)
        {
            SetHighlight(new Point(0.28, 0.12), 8);
            return;
        }
        SetHighlight(new Point(p.X / ActualWidth, p.Y / ActualHeight), amount);
    }

    private void SetHighlight(Point origin, float amount)
    {
        if (_highlightBrush is not null)
        {
            _highlightBrush.Center = _highlightBrush.GradientOrigin = origin;
            _highlightBrush.Opacity = amount > 14 ? 0.84 : amount > 8 ? 0.50 : 0;
        }
        if (EdgeAmount == amount) return;
        EdgeAmount = amount;
        InvalidateGlass();
    }

    private void InvalidateGlass() => GlassInvalidated?.Invoke(this, EventArgs.Empty);

    private static WriteableBitmap CreateShadowImage(int radius)
    {
        // The center pixel stretches into the sides without stretching the rounded corners.
        var stretchStart = ShadowPadding + radius;
        var size = stretchStart * 2 + 1;
        var pixels = new byte[size * size * 4];
        for (var y = 0; y < size; y++)
        for (var x = 0; x < size; x++)
        {
            var fx = x + 0.5 - size / 2d;
            var fy = y + 0.5 - size / 2d;
            var inside = RoundedDistance(fx, fy, radius);
            var shadowDistance = Math.Max(0, RoundedDistance(fx, fy - 4, radius));
            var fade = Math.Max(0, 1 - shadowDistance / (ShadowPadding - 4));
            var alpha = Math.Clamp(inside + 0.5, 0, 1) * fade * fade * fade;
            pixels[(y * size + x) * 4 + 3] = (byte)Math.Round(255 * alpha);
        }
        var bitmap = new WriteableBitmap(size, size);
        using (var buffer = bitmap.PixelBuffer.AsStream()) buffer.Write(pixels);
        bitmap.Invalidate();
        return bitmap;
    }

    private static double RoundedDistance(double x, double y, int radius)
    {
        var qx = Math.Abs(x) - 0.5;
        var qy = Math.Abs(y) - 0.5;
        var dx = Math.Max(qx, 0);
        var dy = Math.Max(qy, 0);
        return Math.Sqrt(dx * dx + dy * dy) + Math.Min(Math.Max(qx, qy), 0) - radius;
    }
}
