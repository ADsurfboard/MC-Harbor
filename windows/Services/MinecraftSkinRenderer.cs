using System.Numerics;

namespace MCHarbor.Windows.Services;

internal sealed record MinecraftSkin(SkinTexture Texture, SkinTexture? Cape);

internal sealed record SkinTexture(byte[] Pixels, int Width, int Height)
{
    public bool IsLegacy => Height * 2 == Width;

    public int Index(float u, float v)
    {
        var scale = Width / 64f;
        var x = Math.Clamp((int)(u * scale), 0, Width - 1);
        var y = Math.Clamp((int)(v * scale), 0, Height - 1);
        return (y * Width + x) * 4;
    }
}

/// <summary>Draws the textured Minecraft model into premultiplied BGRA pixels for XAML.</summary>
internal sealed class MinecraftSkinRenderer(int width, int height)
{
    private const float CameraDistance = 52f;
    private static readonly Vector3 LightDirection = Vector3.Normalize(new Vector3(-0.5f, 0.8f, 1f));
    private readonly byte[] _pixels = new byte[width * height * 4];
    private readonly float[] _depth = new float[width * height];
    private readonly List<Face> _overlays = new(42);
    private readonly float _focalLength = height / (2 * MathF.Tan(MathF.PI / 8));

    public byte[] Draw(MinecraftSkin skin, bool slim, float yaw, float pitch, float stride)
    {
        Array.Clear(_pixels);
        Array.Clear(_depth);
        _overlays.Clear();
        var view = Matrix4x4.CreateRotationY(yaw) * Matrix4x4.CreateRotationX(pitch);
        var texture = skin.Texture;
        var legacy = texture.IsLegacy;
        var armWidth = slim ? 3f : 4f;
        var armAtlasWidth = slim && !legacy ? 3 : 4;
        var armOffset = 4 + armWidth / 2;

        DrawPart(texture, new Vector3(0, 12, 0), new Vector3(8), 8, 8, 8, (0, 0), (32, 0), 1, view);
        DrawPart(texture, new Vector3(0, 2, 0), new Vector3(8, 12, 4), 8, 12, 4, (16, 16),
            legacy ? null : (16, 32), 0.5f, view);
        DrawPart(texture, new Vector3(-armOffset, 2, 0), new Vector3(armWidth, 12, 4), armAtlasWidth, 12, 4,
            (40, 16), legacy ? null : (40, 32), 0.5f, RotatePart(-armOffset, 7, -stride, view));
        DrawPart(texture, new Vector3(armOffset, 2, 0), new Vector3(armWidth, 12, 4), armAtlasWidth, 12, 4,
            legacy ? (40, 16) : (32, 48), legacy ? null : (48, 48), 0.5f,
            RotatePart(armOffset, 7, stride, view), legacy);
        DrawPart(texture, new Vector3(-2, -10, 0), new Vector3(4, 12, 4), 4, 12, 4,
            (0, 16), legacy ? null : (0, 32), 0.5f, RotatePart(-2, -4, stride, view));
        DrawPart(texture, new Vector3(2, -10, 0), new Vector3(4, 12, 4), 4, 12, 4,
            legacy ? (0, 16) : (16, 48), legacy ? null : (0, 48), 0.5f,
            RotatePart(2, -4, -stride, view), legacy);

        if (skin.Cape is { } cape)
        {
            var capeTransform = Matrix4x4.CreateRotationY(MathF.PI)
                * Matrix4x4.CreateRotationX(0.21f + 0.22f * MathF.Abs(stride))
                * Matrix4x4.CreateTranslation(0, 7.7f, -2.55f) * view;
            DrawBox(cape, new Vector3(0, -8, 0), new Vector3(10, 16, 1), 10, 16, 1, 0, 0,
                capeTransform, mirror: false, overlay: true);
        }

        _overlays.Sort(static (left, right) => left.Depth.CompareTo(right.Depth));
        foreach (var face in _overlays) DrawFace(face);
        return _pixels;
    }

    private static Matrix4x4 RotatePart(float x, float y, float angle, Matrix4x4 view) =>
        Matrix4x4.CreateTranslation(-x, -y, 0) * Matrix4x4.CreateRotationX(angle)
        * Matrix4x4.CreateTranslation(x, y, 0) * view;

    private void DrawPart(SkinTexture texture, Vector3 center, Vector3 size, int uWidth, int vHeight, int uDepth,
        (int U, int V) inner, (int U, int V)? outer, float expansion, Matrix4x4 transform, bool mirror = false)
    {
        DrawBox(texture, center, size, uWidth, vHeight, uDepth, inner.U, inner.V, transform, mirror, overlay: false);
        if (outer is { } layer)
            DrawBox(texture, center, size + new Vector3(expansion), uWidth, vHeight, uDepth,
                layer.U, layer.V, transform, mirror, overlay: true);
    }

    private void DrawBox(SkinTexture texture, Vector3 center, Vector3 size,
        int uWidth, int vHeight, int uDepth, int u, int v, Matrix4x4 transform, bool mirror, bool overlay)
    {
        var x = size.X / 2;
        var y = size.Y / 2;
        var z = size.Z / 2;
        var frontTopLeft = new Vector3(-x, y, z);
        var frontTopRight = new Vector3(x, y, z);
        var frontBottomLeft = new Vector3(-x, -y, z);
        var frontBottomRight = new Vector3(x, -y, z);
        var backTopLeft = new Vector3(-x, y, -z);
        var backTopRight = new Vector3(x, y, -z);
        var backBottomLeft = new Vector3(-x, -y, -z);
        var backBottomRight = new Vector3(x, -y, -z);
        var strip = v + uDepth;

        AddFace(frontTopLeft, frontTopRight, frontBottomRight, frontBottomLeft,
            Vector3.UnitZ, u + uDepth, strip, uWidth, vHeight);
        AddFace(backTopRight, backTopLeft, backBottomLeft, backBottomRight,
            -Vector3.UnitZ, u + 2 * uDepth + uWidth, strip, uWidth, vHeight);
        AddFace(backTopLeft, frontTopLeft, frontBottomLeft, backBottomLeft,
            -Vector3.UnitX, u, strip, uDepth, vHeight);
        AddFace(frontTopRight, backTopRight, backBottomRight, frontBottomRight,
            Vector3.UnitX, u + uDepth + uWidth, strip, uDepth, vHeight);
        AddFace(backTopLeft, backTopRight, frontTopRight, frontTopLeft,
            Vector3.UnitY, u + uDepth, v, uWidth, uDepth);
        AddFace(backBottomLeft, backBottomRight, frontBottomRight, frontBottomLeft,
            -Vector3.UnitY, u + uDepth + uWidth, v, uWidth, uDepth);

        void AddFace(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 normal,
            int texX, int texY, int texWidth, int texHeight)
        {
            if (mirror) normal.X = -normal.X;
            var direction = Vector3.TransformNormal(normal, transform);
            a = Transform(a);
            if (Vector3.Dot(direction, new Vector3(0, 0, CameraDistance) - a) <= 0) return;
            b = Transform(b);
            c = Transform(c);
            d = Transform(d);
            var shade = Math.Clamp(0.73f + 0.30f * Vector3.Dot(direction, LightDirection), 0.55f, 1.04f);
            var face = new Face(
                Project(a, texX, texY),
                Project(b, texX + texWidth, texY),
                Project(c, texX + texWidth, texY + texHeight),
                Project(d, texX, texY + texHeight),
                texture, shade, (a.Z + b.Z + c.Z + d.Z) / 4, overlay);
            if (overlay) _overlays.Add(face);
            else DrawFace(face);
        }

        Vector3 Transform(Vector3 vertex)
        {
            if (mirror) vertex.X = -vertex.X;
            return Vector3.Transform(vertex + center, transform);
        }
    }

    private Vertex Project(Vector3 point, float u, float v)
    {
        var depth = 1 / (CameraDistance - point.Z);
        var x = width / 2f + point.X * depth * _focalLength;
        var y = height / 2f - point.Y * depth * _focalLength;
        return new Vertex(x, y, depth, u * depth, v * depth);
    }

    private void DrawFace(Face face)
    {
        DrawTriangle(face.A, face.B, face.C, face);
        DrawTriangle(face.A, face.C, face.D, face);
    }

    private void DrawTriangle(Vertex a, Vertex b, Vertex c, Face face)
    {
        var area = Edge(a, b, c.X, c.Y);
        if (MathF.Abs(area) < 0.001f) return;
        var inverseArea = 1 / area;
        var left = Math.Max(0, (int)MathF.Floor(MathF.Min(a.X, MathF.Min(b.X, c.X))));
        var right = Math.Min(width - 1, (int)MathF.Ceiling(MathF.Max(a.X, MathF.Max(b.X, c.X))));
        var top = Math.Max(0, (int)MathF.Floor(MathF.Min(a.Y, MathF.Min(b.Y, c.Y))));
        var bottom = Math.Min(height - 1, (int)MathF.Ceiling(MathF.Max(a.Y, MathF.Max(b.Y, c.Y))));
        var texture = face.Texture.Pixels;

        for (var y = top; y <= bottom; y++)
        for (var x = left; x <= right; x++)
        {
            var weightA = Edge(b, c, x + 0.5f, y + 0.5f) * inverseArea;
            var weightB = Edge(c, a, x + 0.5f, y + 0.5f) * inverseArea;
            var weightC = 1 - weightA - weightB;
            if (weightA < 0 || weightB < 0 || weightC < 0) continue;
            var depth = weightA * a.Depth + weightB * b.Depth + weightC * c.Depth;
            var pixel = y * width + x;
            if (depth <= _depth[pixel]) continue;
            var u = (weightA * a.U + weightB * b.U + weightC * c.U) / depth;
            var v = (weightA * a.V + weightB * b.V + weightC * c.V) / depth;
            var texel = face.Texture.Index(u, v);
            var alpha = face.Overlay ? texture[texel + 3] : 255;
            if (alpha == 0) continue;
            _depth[pixel] = depth;
            var dest = pixel * 4;
            var remaining = 255 - alpha;
            for (var channel = 0; channel < 3; channel++)
            {
                var shaded = Math.Min(255, (int)(texture[texel + channel] * face.Shade + 0.5f));
                _pixels[dest + channel] = (byte)((shaded * alpha + _pixels[dest + channel] * remaining + 127) / 255);
            }
            _pixels[dest + 3] = (byte)(alpha + (_pixels[dest + 3] * remaining + 127) / 255);
        }
    }

    private static float Edge(Vertex a, Vertex b, float x, float y) =>
        (b.X - a.X) * (y - a.Y) - (b.Y - a.Y) * (x - a.X);

    private readonly record struct Vertex(float X, float Y, float Depth, float U, float V);
    private readonly record struct Face(Vertex A, Vertex B, Vertex C, Vertex D, SkinTexture Texture,
        float Shade, float Depth, bool Overlay);
}
