using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace MCHarbor.Windows.Services;

internal sealed class GlassCardSurface(CanvasDevice device) : IDisposable
{
    private readonly ImageBrush _brush = new() { Stretch = Stretch.Fill };
    private readonly GlassRefractionSurface _refraction = new(device);
    private CanvasImageSource? _image;
    private Rect _bounds;
    private Size _viewport;
    private double _radius;
    private float _edgeAmount;
    private long _revision = -1;

    public ImageBrush Draw(CanvasRenderTarget wallpaper, CanvasRenderTarget blurred, Size viewport,
        Rect bounds, double radius, float edgeAmount, Color fallback, Color tint,
        double diffusion, double edgeOpacity, long revision)
    {
        if (_image is not null && _revision == revision && _bounds == bounds && _viewport == viewport
            && _radius == radius && _edgeAmount == edgeAmount) return _brush;

        var scale = Math.Min(1d, Math.Min(1400d / bounds.Width, 900d / bounds.Height));
        var width = Math.Max(1, (int)Math.Round(bounds.Width * scale));
        var height = Math.Max(1, (int)Math.Round(bounds.Height * scale));
        if (_image?.SizeInPixels.Width != width || _image.SizeInPixels.Height != height)
        {
            _image = new CanvasImageSource(device, width, height, 96);
            _brush.ImageSource = _image;
        }

        var crop = new Rect(bounds.X * wallpaper.SizeInPixels.Width / viewport.Width,
            bounds.Y * wallpaper.SizeInPixels.Height / viewport.Height,
            bounds.Width * wallpaper.SizeInPixels.Width / viewport.Width,
            bounds.Height * wallpaper.SizeInPixels.Height / viewport.Height);
        var frame = new Rect(0, 0, width, height);
        CanvasRenderTarget? edge = null;
        if (edgeOpacity > 0)
        {
            try
            {
                _refraction.Render(wallpaper, viewport, bounds, fallback, edgeAmount, radius);
                edge = _refraction.Surface;
            }
            catch (Exception error) when (error is NotSupportedException or System.Runtime.InteropServices.COMException)
            {
                // The blurred glass remains usable when the graphics driver cannot draw displacement.
            }
        }
        using (var drawing = _image.CreateDrawingSession(fallback))
        {
            GlassWallpaperSampling.Draw(drawing, wallpaper, frame, crop);
            GlassWallpaperSampling.Draw(drawing, blurred, frame, crop, (float)diffusion);
            drawing.FillRectangle(frame, tint);
            if (edge is not null)
                drawing.DrawImage(edge, frame, new Rect(0, 0, edge.SizeInPixels.Width, edge.SizeInPixels.Height),
                    (float)edgeOpacity);
        }
        _bounds = bounds;
        _viewport = viewport;
        _radius = radius;
        _edgeAmount = edgeAmount;
        _revision = revision;
        return _brush;
    }

    public void Dispose()
    {
        _refraction.Dispose();
        _brush.ImageSource = null;
        _image = null;
    }
}
