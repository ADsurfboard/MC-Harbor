using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace MCHarbor.Windows.Services;

internal static class MinecraftSkinLoader
{
    public static async Task<MinecraftSkin> LoadAsync(string path, string? capePath = null)
    {
        var texture = await LoadTextureAsync(path, cape: false);
        SkinTexture? cape = null;
        if (capePath is not null)
        {
            try { cape = await LoadTextureAsync(capePath, cape: true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException
                or ArgumentException or System.Runtime.InteropServices.COMException) { }
        }
        return new MinecraftSkin(texture, cape);
    }

    public static WriteableBitmap CreateAvatar(SkinTexture texture)
    {
        const int size = 72;
        var avatar = new WriteableBitmap(size, size);
        var pixels = new byte[size * size * 4];
        for (var y = 0; y < size; y++)
        for (var x = 0; x < size; x++)
        {
            var u = (x + 0.5f) * 8 / size;
            var v = (y + 0.5f) * 8 / size;
            var face = texture.Index(8 + u, 8 + v);
            var hat = texture.Index(40 + u, 8 + v);
            var alpha = texture.Pixels[hat + 3];
            var pixel = (y * size + x) * 4;
            for (var channel = 0; channel < 3; channel++)
            {
                var top = texture.Pixels[hat + channel] * alpha;
                var bottom = texture.Pixels[face + channel] * (255 - alpha);
                pixels[pixel + channel] = (byte)((top + bottom + 127) / 255);
            }
            pixels[pixel + 3] = 255;
        }
        using (var buffer = avatar.PixelBuffer.AsStream()) buffer.Write(pixels);
        avatar.Invalidate();
        return avatar;
    }

    private static async Task<SkinTexture> LoadTextureAsync(string path, bool cape)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var input = await file.OpenReadAsync();
        if (input.Size is 0 or > 4_000_000) throw new InvalidDataException("皮肤纹理超过 4 MB。");
        var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.PngDecoderId, input);
        var width = (int)decoder.PixelWidth;
        var height = (int)decoder.PixelHeight;
        if (width is < 64 or > 2048 || (height != width && height * 2 != width))
            throw new InvalidDataException(cape ? "披风纹理尺寸无效。" : "Minecraft 皮肤纹理尺寸无效。");

        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight,
            new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        var pixels = data.DetachPixelData();
        if (!cape && height * 2 == width) ClearOpaqueLegacyHat(pixels, width, height);
        return new SkinTexture(pixels, width, height);
    }

    private static void ClearOpaqueLegacyHat(byte[] pixels, int width, int height)
    {
        // Old skins sometimes store an opaque filler in the entire hat area.
        for (var y = 0; y < height / 2; y++)
            for (var x = width / 2; x < width; x++)
                if (pixels[(y * width + x) * 4 + 3] < 128) return;

        for (var y = 0; y < height / 2; y++)
            for (var x = width / 2; x < width; x++)
                pixels[(y * width + x) * 4 + 3] = 0;
    }
}
