using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MCHarbor.Windows.Services;

internal sealed class WindowsProcessJob : IDisposable
{
    private readonly SafeFileHandle _job;

    private WindowsProcessJob(SafeFileHandle job) => _job = job;

    public static WindowsProcessJob Start(string executable, string argument, string workingDirectory)
    {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job.IsInvalid)
        {
            var failure = new Win32Exception(Marshal.GetLastWin32Error());
            job.Dispose();
            throw failure;
        }
        var limits = new ExtendedLimits { Basic = new BasicLimits { LimitFlags = 0x2000 } };
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        var environment = ProcessEnvironment(workingDirectory);
        var block = Marshal.StringToHGlobalUni(environment);
        try
        {
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法设置联机进程退出规则。");
            var commandLine = new StringBuilder($"\"{executable}\" --hmcl \"{argument}\"");
            const uint suspendedWithoutConsole = 0x00000004 | 0x00000400 | 0x08000000;
            if (!CreateProcessW(executable, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                    suspendedWithoutConsole, block, workingDirectory, ref startup, out var process))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法启动陶瓦客户端。");
            try
            {
                if (!AssignProcessToJobObject(job, process.Process) || ResumeThread(process.Thread) == uint.MaxValue)
                {
                    var error = Marshal.GetLastWin32Error();
                    TerminateProcess(process.Process, 1);
                    throw new Win32Exception(error, "无法管理陶瓦后台进程。");
                }
            }
            finally
            {
                CloseHandle(process.Thread);
                CloseHandle(process.Process);
            }
            return new WindowsProcessJob(job);
        }
        catch
        {
            job.Dispose();
            throw;
        }
        finally { Marshal.FreeHGlobal(block); }
    }

    public void Dispose() => _job.Dispose();

    private static string ProcessEnvironment(string workingDirectory)
    {
        var values = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry pair in Environment.GetEnvironmentVariables())
            if (pair.Key is string key && pair.Value is string value) values[key] = value;
        values["TEMP"] = values["TMP"] = workingDirectory;
        return string.Join('\0', values.Select(pair => pair.Key + "=" + pair.Value)) + "\0\0";
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemory, PeakJobMemory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, Width, Height, CountX, CountY, FillAttribute, Flags;
        public ushort ShowWindow, ReservedCount;
        public IntPtr ReservedBytes, Input, Output, Error;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo
    {
        public IntPtr Process, Thread;
        public uint ProcessId, ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags,
        IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern bool TerminateProcess(IntPtr process, uint code);
}
