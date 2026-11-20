using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.Foundation;
using Windows.UI;

namespace MCHarbor.Windows.Services;

/// <summary>Owns the opaque in-app wallpaper used by the window and its glass surfaces.</summary>
internal sealed class HarborBackdrop(CanvasDevice device) : IDisposable
{
    public CanvasRenderTarget? Surface { get; private set; }
    public CanvasImageSource? ImageSource { get; private set; }

    public void Draw(Size viewport, Color start, Color end, Color glow, ICanvasImage? wallpaper,
        double dimming, double softness)
    {
        var scale = Math.Min(1d, Math.Min(1920 / viewport.Width, 1080 / viewport.Height));
        var width = Math.Max(1, (int)Math.Round(viewport.Width * scale));
        var height = Math.Max(1, (int)Math.Round(viewport.Height * scale));
        var bounds = new Rect(0, 0, width, height);
        if (Surface?.SizeInPixels.Width != width || Surface.SizeInPixels.Height != height)
        {
            Dispose();
            ImageSource = new CanvasImageSource(device, width, height, 96);
            Surface = new CanvasRenderTarget(device, width, height, 96);
        }

        using (var drawing = Surface.CreateDrawingSession())
        {
            drawing.Clear(start);
            using var gradient = new CanvasLinearGradientBrush(device, start, end)
            {
                StartPoint = Vector2.Zero,
                EndPoint = new Vector2(width, height)
            };
            using var halo = new CanvasRadialGradientBrush(device, glow, Color.FromArgb(0, glow.R, glow.G, glow.B))
            {
                Center = new Vector2(width * 0.26f, height * 0.26f),
                RadiusX = width * 0.78f,
                RadiusY = height * 0.95f
            };
            drawing.FillRectangle(bounds, gradient);
            drawing.FillRectangle(bounds, halo);

            if (wallpaper is not null)
            {
                var source = wallpaper.GetBounds(device);
                var cover = Math.Max(width / source.Width, height / source.Height);
                var crop = new Rect(source.X + (source.Width - width / cover) / 2,
                    source.Y + (source.Height - height / cover) / 2, width / cover, height / cover);
                using var layer = drawing.CreateLayer((float)(1 - dimming), bounds);
                if (softness > 0)
                {
                    using var blur = CreateBlur(wallpaper, (float)(softness * scale / cover));
                    drawing.DrawImage(blur, bounds, crop);
                }
                else drawing.DrawImage(wallpaper, bounds, crop);
            }
        }

        using var output = ImageSource!.CreateDrawingSession(start);
        output.DrawImage(Surface);
    }

    internal static GaussianBlurEffect CreateBlur(ICanvasImage image, float radius) => new()
    {
        Source = (global::Windows.Graphics.Effects.IGraphicsEffectSource)image,
        BlurAmount = Math.Clamp(radius, 0, 64),
        BorderMode = EffectBorderMode.Hard,
        Optimization = EffectOptimization.Balanced
    };

    public void Dispose()
    {
        Surface?.Dispose();
        Surface = null;
        ImageSource = null;
    }
}

internal sealed class GlassWallpaperBlur(CanvasDevice device) : IDisposable
{
    private CanvasRenderTarget? _surface;
    private long _revision = -1;

    public CanvasRenderTarget GetSurface(CanvasRenderTarget wallpaper, Size viewport, double radius, long revision)
    {
        if (_surface is not null && _revision == revision) return _surface;
        var width = (int)wallpaper.SizeInPixels.Width;
        var height = (int)wallpaper.SizeInPixels.Height;
        if (_surface?.SizeInPixels.Width != width || _surface.SizeInPixels.Height != height)
        {
            Dispose();
            _surface = new CanvasRenderTarget(device, width, height, 96);
        }
        var scale = Math.Min(width / viewport.Width, height / viewport.Height);
        using var effect = HarborBackdrop.CreateBlur(wallpaper, (float)(radius * scale));
        using (var drawing = _surface.CreateDrawingSession())
        {
            drawing.Clear(Microsoft.UI.Colors.Transparent);
            drawing.DrawImage(effect);
        }
        _revision = revision;
        return _surface;
    }

    public void Dispose()
    {
        _surface?.Dispose();
        _surface = null;
        _revision = -1;
    }
}
