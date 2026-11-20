using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using MCHarbor.Windows.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using VirtualKey = global::Windows.System.VirtualKey;

namespace MCHarbor.Windows.Controls;

public sealed class MinecraftSkinViewport : UserControl
{
    private const int PreviewSize = 384;
    private readonly Image _image = new() { Stretch = Stretch.Uniform, IsHitTestVisible = false };
    private MinecraftSkin? _skin;
    private MinecraftSkinRenderer? _renderer;
    private WriteableBitmap? _bitmap;
    private DispatcherQueueTimer? _timer;
    private Stream? _pixelBuffer;
    private long _timestamp;
    private float _yaw = 0.35f;
    private float _pitch = -0.10f;
    private float _stride;
    private float _walkTime;
    private bool _slim;
    private bool _animate;
    private string _motion = "none";
    private Point _pointer;
    private uint? _pointerId;

    public MinecraftSkinViewport()
    {
        var stage = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        stage.Children.Add(_image);
        Content = stage;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Stretch;
        IsTabStop = false;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, "Minecraft 三维皮肤预览");
        AutomationProperties.SetHelpText(this, "拖动角色或使用方向键旋转");
        Loaded += (_, _) => UpdateTimer();
        Unloaded += (_, _) =>
        {
            _timer?.Stop();
            _pointerId = null;
            _pixelBuffer?.Dispose();
            _pixelBuffer = null;
        };
        PointerPressed += StartDrag;
        PointerMoved += Drag;
        PointerReleased += EndDrag;
        PointerCanceled += EndDrag;
        PointerCaptureLost += EndDrag;
        KeyDown += RotateByKey;
    }

    internal void ShowSkin(MinecraftSkin? skin, bool slim)
    {
        _skin = skin;
        _slim = slim;
        _yaw = 0.35f;
        _pitch = -0.10f;
        _walkTime = _stride = 0;
        _pointerId = null;
        ReleasePointerCaptures();
        IsTabStop = skin is not null;
        if (skin is null) _image.Source = null;
        else Draw();
        UpdateTimer();
    }

    internal void SetOptions(bool slim, string motion, bool animate)
    {
        var changed = _slim != slim || _motion != motion;
        if (_motion != motion) _walkTime = _stride = 0;
        _slim = slim;
        _motion = motion;
        _animate = animate;
        if (changed) Draw();
        UpdateTimer();
    }

    private void Draw()
    {
        if (_skin is not { } skin) return;
        _renderer ??= new MinecraftSkinRenderer(PreviewSize, PreviewSize);
        _bitmap ??= new WriteableBitmap(PreviewSize, PreviewSize);
        var pixels = _renderer.Draw(skin, _slim, _yaw, _pitch, _stride);
        _pixelBuffer ??= _bitmap.PixelBuffer.AsStream();
        _pixelBuffer.Position = 0;
        _pixelBuffer.Write(pixels);
        _bitmap.Invalidate();
        if (!ReferenceEquals(_image.Source, _bitmap)) _image.Source = _bitmap;
    }

    private void UpdateTimer()
    {
        if (_skin is null || _motion == "none" || _pointerId.HasValue || !_animate || !IsLoaded)
        {
            _timer?.Stop();
            return;
        }
        if (_timer is null)
        {
            _timer = DispatcherQueue.CreateTimer();
            _timer.Interval = TimeSpan.FromSeconds(1d / 24);
            _timer.Tick += (_, _) => Animate();
        }
        if (_timer.IsRunning) return;
        _timestamp = Stopwatch.GetTimestamp();
        _timer.Start();
    }

    private void Animate()
    {
        var now = Stopwatch.GetTimestamp();
        var elapsed = Math.Min(0.1f, (now - _timestamp) / (float)Stopwatch.Frequency);
        _timestamp = now;
        if (_motion == "rotate") _yaw = (_yaw + elapsed * 0.9f) % MathF.Tau;
        else
        {
            _walkTime = (_walkTime + elapsed * 5f) % MathF.Tau;
            _stride = 0.52f * MathF.Sin(_walkTime);
        }
        Draw();
    }

    private void StartDrag(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(this);
        if (_skin is null || _pointerId.HasValue || !point.IsInContact) return;
        if (!CapturePointer(args.Pointer)) return;
        Focus(FocusState.Pointer);
        _pointerId = args.Pointer.PointerId;
        _pointer = point.Position;
        UpdateTimer();
        args.Handled = true;
    }

    private void Drag(object sender, PointerRoutedEventArgs args)
    {
        if (_pointerId != args.Pointer.PointerId) return;
        var position = args.GetCurrentPoint(this).Position;
        Rotate((float)(position.X - _pointer.X) * 0.013f, (float)(position.Y - _pointer.Y) * 0.01f);
        _pointer = position;
        args.Handled = true;
    }

    private void EndDrag(object sender, PointerRoutedEventArgs args)
    {
        if (_pointerId != args.Pointer.PointerId) return;
        _pointerId = null;
        ReleasePointerCapture(args.Pointer);
        UpdateTimer();
        args.Handled = true;
    }

    private void RotateByKey(object sender, KeyRoutedEventArgs args)
    {
        if (_skin is null) return;
        var (yaw, pitch) = args.Key switch
        {
            VirtualKey.Left => (-0.16f, 0f),
            VirtualKey.Right => (0.16f, 0f),
            VirtualKey.Up => (0f, -0.10f),
            VirtualKey.Down => (0f, 0.10f),
            _ => (0f, 0f)
        };
        if (yaw == 0 && pitch == 0) return;
        Rotate(yaw, pitch);
        args.Handled = true;
    }

    private void Rotate(float yaw, float pitch)
    {
        _yaw = (_yaw + yaw) % MathF.Tau;
        _pitch = Math.Clamp(_pitch + pitch, -0.62f, 0.62f);
        Draw();
    }
}
