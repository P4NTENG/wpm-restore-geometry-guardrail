using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class P {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MINMAXINFO { public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MI { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam, lParam;
        public uint time; public int ptL, ptT;
    }

    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, ref MINMAXINFO l);
    [DllImport("user32.dll", EntryPoint="GetWindowRect")]
    public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint="MonitorFromWindow")]
    public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll", EntryPoint="MonitorFromPoint")]
    public static extern IntPtr MonitorFromPoint(POINT p, uint f);
    [DllImport("user32.dll", EntryPoint="GetMonitorInfoW")]
    public static extern bool GetMonitorInfoW(IntPtr m, ref MI mi);
    [DllImport("user32.dll", EntryPoint="GetDpiForWindow")]
    public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll", EntryPoint="GetDpiForSystem")]
    public static extern uint GetDpiForSystem();
    [DllImport("user32.dll", EntryPoint="IsWindowVisible")]
    public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", EntryPoint="IsIconic")]
    public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumWindows")]
    public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", EntryPoint="SetWinEventHook")]
    public static extern IntPtr SetWinEventHook(uint a, uint b, IntPtr m, WinEventProc cb, uint pid, uint tid, uint f);
    [DllImport("user32.dll", EntryPoint="UnhookWinEvent")]
    public static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll", EntryPoint="PeekMessageW")]
    public static extern bool PeekMessage(IntPtr m, IntPtr h, uint a, uint b, uint c);
    [DllImport("user32.dll", EntryPoint="GetWindowTextW")]
    public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", EntryPoint="GetClassNameW")]
    public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time);

    public const uint EVENT_SYSTEM_MINIMIZESTART = 0x0016;
    public const uint EVENT_SYSTEM_MINIMIZEEND   = 0x0017;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    public const uint WM_GETMINMAXINFO = 0x0024;
}

class Program {
    static Stopwatch Clock = Stopwatch.StartNew();
    static IntPtr Target = IntPtr.Zero;
    static List<string> Rows = new List<string>();
    static readonly object Gate = new object();
    // The hook keeps only a raw function pointer. If the delegate were a
    // local it could be collected while the hook still points at it, and
    // the first event would call freed memory. Rooted for the process.
    static P.WinEventProc HookCb;
    static Dictionary<IntPtr, uint> MonDpi = new Dictionary<IntPtr, uint>();

    static string Ms() { return Clock.Elapsed.TotalMilliseconds.ToString("F3", CultureInfo.InvariantCulture); }

    static void BuildMonMap() {
        MonDpi.Clear();
        P.EnumWindows((h, p) => {
            if (P.IsWindowVisible(h)) {
                IntPtr m = P.MonitorFromWindow(h, 2);
                uint d = P.GetDpiForWindow(h);
                if (m != IntPtr.Zero && d > 0 && !MonDpi.ContainsKey(m)) MonDpi[m] = d;
            }
            return true; }, IntPtr.Zero);
    }

    static uint DpiOf(IntPtr m) { uint d; return MonDpi.TryGetValue(m, out d) ? d : 0; }

    static int MaxRows = 400000;
    static long RowCount = 0;
    static void Row(string kind, string body) {
        lock (Gate) {
            if (RowCount >= MaxRows) return;
            RowCount++;
            Rows.Add(Ms() + "," + kind + "," + body);
        }
    }

    static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time) {
        try {
        if (hwnd != Target) return;
        P.RECT r; P.GetWindowRect(hwnd, out r);
        IntPtr m = P.MonitorFromWindow(hwnd, 2);
        string name =
            ev == P.EVENT_SYSTEM_MINIMIZESTART   ? "MINIMIZESTART" :
            ev == P.EVENT_SYSTEM_MINIMIZEEND     ? "MINIMIZEEND"   :
            ev == P.EVENT_OBJECT_LOCATIONCHANGE  ? "LOCATIONCHANGE" : ("EV" + ev.ToString("X"));
        // No message is sent to the target from inside this callback. The
        // callback runs while the target is handling its own event, and a
        // synchronous SendMessage back into it from there reenters the
        // window procedure and hangs the process. The sampling loop below
        // reads the track size on its own thread.
        Row("EVENT", name + ",sysTime=" + time + ",rect=" + r.L + "x" + r.T + " " + (r.R - r.L) + "x" + (r.B - r.T)
            + ",mon=" + m.ToInt64() + ",monDpi=" + DpiOf(m) + ",iconic=" + P.IsIconic(hwnd)
            + ",dpiW=" + P.GetDpiForWindow(hwnd));
        } catch { }
    }

    static IntPtr FindChrome() {
        IntPtr f = IntPtr.Zero;
        P.EnumWindows((h, p) => {
            var c = new StringBuilder(256); P.GetClassNameW(h, c, 256);
            if (c.ToString() == "Chrome_WidgetWin_1" && P.IsWindowVisible(h)) { f = h; return false; }
            return true; }, IntPtr.Zero);
        return f;
    }

    static int Main(string[] args) {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        long hwndArg = (args.Length > 0) ? long.Parse(args[0]) : 0;
        int ms = (args.Length > 1) ? int.Parse(args[1]) : 12000;
        string outPath = (args.Length > 2) ? args[2] : Path.Combine(Path.GetTempPath(), "tl2.csv");

        Target = hwndArg != 0 ? new IntPtr(hwndArg) : FindChrome();
        if (Target == IntPtr.Zero) { Console.WriteLine("chrome not found"); return 1; }
        var title = new StringBuilder(300); P.GetWindowTextW(Target, title, 300);
        Console.WriteLine("hwnd=" + Target.ToInt64() + "  " + title.ToString());

        BuildMonMap();
        HookCb = OnEvent;
        P.WinEventProc cb = HookCb;
        // Two ranges: the system minimise pair and location change, which
        // sit far apart in the event id space.
        // Only the minimise pair. LOCATIONCHANGE fires thousands of times
        // a second on this window and the out of context queue cannot keep
        // up, which takes the process down before the transition is seen.
        IntPtr h1 = P.SetWinEventHook(P.EVENT_SYSTEM_MINIMIZESTART, P.EVENT_SYSTEM_MINIMIZEEND, IntPtr.Zero, cb, 0, 0, 0);
        Console.WriteLine("hook=" + h1.ToInt64());

        Clock.Restart();
        Rows.Add("t_ms,kind,body");
        IntPtr msg = Marshal.AllocHGlobal(64);
        long samples = 0, events = 0;
        while (Clock.ElapsedMilliseconds < ms) {
            // Drain first so callbacks run with the tightest possible
            // latency, then take one sample straight after.
            int drained = 0;
            while (P.PeekMessage(msg, IntPtr.Zero, 0, 0, 1)) { drained++; if (drained > 256) break; }
            P.MINMAXINFO mm = new P.MINMAXINFO();
            P.SendMessageW(Target, P.WM_GETMINMAXINFO, IntPtr.Zero, ref mm);
            P.RECT r; P.GetWindowRect(Target, out r);
            IntPtr m = P.MonitorFromWindow(Target, 2);
            Row("SAMPLE", "minTrack=" + mm.ptMinTrackSize.X + ",width=" + (r.R - r.L)
                + ",mon=" + m.ToInt64() + ",monDpi=" + DpiOf(m) + ",dpiW=" + P.GetDpiForWindow(Target)
                + ",sysDpi=" + P.GetDpiForSystem());
            samples++;
        }
        P.UnhookWinEvent(h1);
        lock (Gate) events = Rows.Count;
        File.WriteAllLines(outPath, Rows);
        Console.WriteLine("samples=" + samples + "  rows=" + events + "  -> " + outPath);
        return 0;
    }
}
