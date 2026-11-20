using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Windows.Foundation;
using Windows.Graphics.DirectX;
using Windows.UI;

namespace MCHarbor.Windows.Services;

/// <summary>Renders a rounded glass edge by displacing the wallpaper pixels sampled beneath a card.</summary>
internal sealed class GlassRefractionSurface : IDisposable
{
    private readonly CanvasDevice _device;
    private CanvasRenderTarget? _sample;
    private CanvasRenderTarget? _output;
    private CanvasBitmap? _displacementMap;
    private CanvasBitmap? _edgeMask;
    private DisplacementMapEffect? _displacement;
    private AlphaMaskEffect? _maskedDisplacement;
    private int _width;
    private int _height;
    private int _margin;
    private double _renderScale = 1;
    private double _cornerRadius;
    private bool _disposed;

    public GlassRefractionSurface(CanvasDevice device) => _device = device;

    public CanvasRenderTarget? Surface => _output;

    public void Render(CanvasRenderTarget wallpaper, Size viewport, Rect cardBounds, Color fallbackColor,
        float amount, double cornerRadius)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (viewport.Width <= 0 || viewport.Height <= 0
            || cardBounds.Width <= 0 || cardBounds.Height <= 0) return;

        var renderScale = Math.Min(0.60d, Math.Min(680d / cardBounds.Width, 440d / cardBounds.Height));
        var width = Math.Max(1, (int)Math.Ceiling(cardBounds.Width * renderScale));
        var height = Math.Max(1, (int)Math.Ceiling(cardBounds.Height * renderScale));
        if (_width != width || _height != height || _cornerRadius != cornerRadius)
            CreateSurfaces(width, height, renderScale, cornerRadius);

        var scaleX = wallpaper.SizeInPixels.Width / viewport.Width;
        var scaleY = wallpaper.SizeInPixels.Height / viewport.Height;
        var marginX = _margin * cardBounds.Width / width;
        var marginY = _margin * cardBounds.Height / height;
        var expandedCard = new Rect(
            cardBounds.X - marginX, cardBounds.Y - marginY,
            cardBounds.Width + marginX * 2, cardBounds.Height + marginY * 2);
        var sourceRect = new Rect(
            expandedCard.X * scaleX, expandedCard.Y * scaleY,
            expandedCard.Width * scaleX, expandedCard.Height * scaleY);
        var sampleBounds = new Rect(0, 0, width + _margin * 2, height + _margin * 2);

        using (var drawing = _sample!.CreateDrawingSession())
        {
            drawing.Clear(fallbackColor);
            GlassWallpaperSampling.Draw(drawing, wallpaper, sampleBounds, sourceRect);
        }

        _displacement!.Amount = (float)Math.Clamp(amount * _renderScale, 0, 32 * _renderScale);
        using var output = _output!.CreateDrawingSession();
        output.Clear(Color.FromArgb(0, 0, 0, 0));
        output.DrawImage(_maskedDisplacement!, new Rect(0, 0, width, height),
            new Rect(_margin, _margin, width, height));
    }

    private void CreateSurfaces(int width, int height, double renderScale, double cornerRadius)
    {
        ReleaseSurfaces();
        var margin = Math.Max(8, (int)Math.Ceiling(16 * renderScale));
        var sampleWidth = width + margin * 2;
        var sampleHeight = height + margin * 2;
        _sample = new CanvasRenderTarget(_device, sampleWidth, sampleHeight, 96);
        _output = new CanvasRenderTarget(_device, width, height, 96);
        var radius = Math.Min(cornerRadius * renderScale, Math.Min(width, height) / 2d);
        _displacementMap = CanvasBitmap.CreateFromBytes(_device,
            CreateDisplacementPixels(width, height, margin, radius), sampleWidth, sampleHeight,
            DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
        _edgeMask = CanvasBitmap.CreateFromBytes(_device,
            CreateEdgeMaskPixels(width, height, margin, radius, renderScale), sampleWidth, sampleHeight,
            DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
        _displacement = new DisplacementMapEffect
        {
            Source = _sample,
            Displacement = _displacementMap,
            XChannelSelect = EffectChannelSelect.Red,
            YChannelSelect = EffectChannelSelect.Green,
            Amount = 14
        };
        _maskedDisplacement = new AlphaMaskEffect
        {
            Source = _displacement,
            AlphaMask = _edgeMask
        };
        _width = width;
        _height = height;
        _margin = margin;
        _renderScale = renderScale;
        _cornerRadius = cornerRadius;
    }

    private static byte[] CreateDisplacementPixels(int width, int height, int margin, double radius)
    {
        var sampleWidth = width + margin * 2;
        var sampleHeight = height + margin * 2;
        var pixels = new byte[checked(sampleWidth * sampleHeight * 4)];
        for (var y = 0; y < sampleHeight; y++)
        for (var x = 0; x < sampleWidth; x++)
        {
            var dx = x + 0.5 - margin - width / 2d;
            var dy = y + 0.5 - margin - height / 2d;
            var qx = Math.Abs(dx) - (width / 2d - radius);
            var qy = Math.Abs(dy) - (height / 2d - radius);
            var outsideX = Math.Max(qx, 0);
            var outsideY = Math.Max(qy, 0);
            var outsideLength = Math.Sqrt(outsideX * outsideX + outsideY * outsideY);
            double normalX;
            double normalY;
            if (outsideLength > 0.001)
            {
                normalX = Math.Sign(dx) * outsideX / outsideLength;
                normalY = Math.Sign(dy) * outsideY / outsideLength;
            }
            else if (qx >= qy)
            {
                normalX = Math.Sign(dx);
                normalY = 0;
            }
            else
            {
                normalX = 0;
                normalY = Math.Sign(dy);
            }

            var index = (y * sampleWidth + x) * 4;
            pixels[index] = 128;
            pixels[index + 1] = (byte)Math.Clamp((int)Math.Round(128 + normalY * 127), 0, 255);
            pixels[index + 2] = (byte)Math.Clamp((int)Math.Round(128 + normalX * 127), 0, 255);
            pixels[index + 3] = 255;
        }
        return pixels;
    }

    private static byte[] CreateEdgeMaskPixels(int width, int height, int margin, double radius, double scale)
    {
        var sampleWidth = width + margin * 2;
        var sampleHeight = height + margin * 2;
        var pixels = new byte[checked(sampleWidth * sampleHeight * 4)];
        var edgeWidth = Math.Max(3, 11 * scale);
        for (var y = margin; y < margin + height; y++)
        for (var x = margin; x < margin + width; x++)
        {
            var dx = Math.Abs(x + 0.5 - margin - width / 2d) - (width / 2d - radius);
            var dy = Math.Abs(y + 0.5 - margin - height / 2d) - (height / 2d - radius);
            var outside = Math.Sqrt(Math.Pow(Math.Max(dx, 0), 2) + Math.Pow(Math.Max(dy, 0), 2));
            var signedDistance = outside + Math.Min(Math.Max(dx, dy), 0) - radius;
            var insideDistance = -signedDistance;
            if (insideDistance < 0 || insideDistance > edgeWidth) continue;

            var normalized = Math.Clamp(1 - insideDistance / edgeWidth, 0, 1);
            var smooth = normalized * normalized * (3 - 2 * normalized);
            var alpha = (byte)Math.Clamp((int)Math.Round(74 * smooth), 0, 74);
            var index = (y * sampleWidth + x) * 4;
            pixels[index] = alpha;
            pixels[index + 1] = alpha;
            pixels[index + 2] = alpha;
            pixels[index + 3] = alpha;
        }
        return pixels;
    }

    private void ReleaseSurfaces()
    {
        _maskedDisplacement?.Dispose();
        _maskedDisplacement = null;
        _displacement?.Dispose();
        _displacement = null;
        _edgeMask?.Dispose();
        _edgeMask = null;
        _displacementMap?.Dispose();
        _displacementMap = null;
        _sample?.Dispose();
        _sample = null;
        _output?.Dispose();
        _output = null;
        _width = 0;
        _height = 0;
        _margin = 0;
        _renderScale = 1;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        ReleaseSurfaces();
    }
}
