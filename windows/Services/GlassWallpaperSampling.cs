using Microsoft.Graphics.Canvas;
using Windows.Foundation;

namespace MCHarbor.Windows.Services;

internal static class GlassWallpaperSampling
{
    internal static bool TryClip(Rect source, Rect destination, Size wallpaperSize,
        out Rect clippedSource, out Rect clippedDestination)
    {
        var left = Math.Max(0, source.Left);
        var top = Math.Max(0, source.Top);
        var right = Math.Min(wallpaperSize.Width, source.Right);
        var bottom = Math.Min(wallpaperSize.Height, source.Bottom);
        if (right <= left || bottom <= top)
        {
            clippedSource = clippedDestination = Rect.Empty;
            return false;
        }

        // Clip both rectangles at the same scale so visible wallpaper pixels retain their positions.
        var scaleX = destination.Width / source.Width;
        var scaleY = destination.Height / source.Height;
        clippedSource = new Rect(left, top, right - left, bottom - top);
        clippedDestination = new Rect(destination.X + (left - source.X) * scaleX,
            destination.Y + (top - source.Y) * scaleY, clippedSource.Width * scaleX, clippedSource.Height * scaleY);
        return true;
    }

    internal static void Draw(CanvasDrawingSession drawing, CanvasRenderTarget wallpaper, Rect destination, Rect source,
        float opacity = 1)
    {
        if (TryClip(source, destination, wallpaper.Size, out var visibleSource, out var visibleDestination))
            drawing.DrawImage(wallpaper, visibleDestination, visibleSource, opacity);
    }
}
