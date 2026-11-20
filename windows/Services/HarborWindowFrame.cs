using System.Runtime.InteropServices;

namespace MCHarbor.Windows.Services;

internal sealed class HarborWindowFrame : IDisposable
{
    private const uint NonClientCalculateSize = 0x0083;
    private const uint NonClientHitTest = 0x0084;
    private const uint NonClientDestroy = 0x0082;
    private const uint FrameChangedWithoutMoveOrResize = 0x237;
    private const int Client = 1;
    private const int Caption = 2;
    private const int Left = 10;
    private const int Right = 11;
    private const int Top = 12;
    private const int TopLeft = 13;
    private const int TopRight = 14;
    private const int Bottom = 15;
    private const int BottomLeft = 16;
    private const int BottomRight = 17;

    private readonly nint _window;
    private readonly SubclassCallback _callback;
    private readonly nuint _id;
    private bool _attached;

    public HarborWindowFrame(nint window)
    {
        _window = window;
        _callback = HandleMessage;
        _id = unchecked((nuint)Marshal.GetFunctionPointerForDelegate(_callback));
        _attached = SetWindowSubclass(window, _callback, _id, 0);
        if (_attached) SetWindowPos(window, 0, 0, 0, 0, 0, FrameChangedWithoutMoveOrResize);
    }

    private nint HandleMessage(nint window, uint message, nuint wparam, nint lparam, nuint id, nuint reference)
    {
        if (message == NonClientDestroy)
        {
            Dispose();
        }
        else if (message == NonClientCalculateSize && lparam != 0)
        {
            // Let XAML cover the resize frame. When maximized, preserve the monitor's taskbar area.
            if (IsZoomed(window))
            {
                var monitor = MonitorFromWindow(window, 2);
                var screen = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
                if (monitor == 0 || !GetMonitorInfo(monitor, ref screen))
                    return DefSubclassProc(window, message, wparam, lparam);
                Marshal.StructureToPtr(screen.WorkArea, lparam, false);
            }
            return 0;
        }
        else if (message == NonClientHitTest && GetWindowRect(window, out var bounds))
        {
            var x = (short)((long)lparam & 0xFFFF) - bounds.Left;
            var y = (short)(((long)lparam >> 16) & 0xFFFF) - bounds.Top;
            var dpi = Math.Max(96u, GetDpiForWindow(window));
            var scale = dpi / 96d;
            if (!IsZoomed(window))
            {
                var width = bounds.Right - bounds.Left;
                var height = bounds.Bottom - bounds.Top;
                const int horizontalFrame = 32;
                const int verticalFrame = 33;
                const int paddedBorder = 92;
                var padding = GetSystemMetricsForDpi(paddedBorder, dpi);
                var edgeX = GetSystemMetricsForDpi(horizontalFrame, dpi) + padding;
                var edgeY = GetSystemMetricsForDpi(verticalFrame, dpi) + padding;
                if (y < edgeY) return x < edgeX ? TopLeft : x >= width - edgeX ? TopRight : Top;
                if (y >= height - edgeY) return x < edgeX ? BottomLeft : x >= width - edgeX ? BottomRight : Bottom;
                if (x < edgeX) return Left;
                if (x >= width - edgeX) return Right;
            }
            return x >= 70 * scale && y >= 0 && y < 28 * scale ? Caption : Client;
        }
        return DefSubclassProc(window, message, wparam, lparam);
    }

    public void Dispose()
    {
        if (!_attached) return;
        RemoveWindowSubclass(_window, _callback, _id);
        _attached = false;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public uint Size; public WindowRect Monitor, WorkArea; public uint Flags; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassCallback(nint window, uint message, nuint wparam, nint lparam, nuint id, nuint reference);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint window, SubclassCallback callback, nuint id, nuint reference);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint window, SubclassCallback callback, nuint id);
    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint window, uint message, nuint wparam, nint lparam);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint window, out WindowRect bounds);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsZoomed(nint window);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")]
    private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
}
