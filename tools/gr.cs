using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class G {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MINMAXINFO { public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, ref MINMAXINFO l);
    [DllImport("user32.dll", EntryPoint="GetWindowRect")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint="SetWindowPos")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int ht, uint f);
    [DllImport("user32.dll", EntryPoint="MonitorFromWindow")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll", EntryPoint="GetDpiForWindow")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll", EntryPoint="IsIconic")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", EntryPoint="IsZoomed")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", EntryPoint="ShowWindow")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll", EntryPoint="GetWindowTextW")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    public const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

    public static MINMAXINFO Track(IntPtr h) { var m = new MINMAXINFO(); SendMessageW(h, 0x0024, IntPtr.Zero, ref m); return m; }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    public static string Fmt(RECT r) { return r.L + "," + r.T + " " + (r.R - r.L) + "x" + (r.B - r.T); }
}

class Program {
    static Stopwatch Clock = Stopwatch.StartNew();
    static IntPtr Target;
    static List<string> L = new List<string>();
    static void Say(string s) { lock (L) L.Add(Clock.Elapsed.TotalMilliseconds.ToString("F3") + "," + s); }
    static void Hdr(string s) { lock (L) L.Add("# " + s); }

    static void Main(string[] a) {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        long hwnd = long.Parse(a[0]);
        int ex = int.Parse(a[1]), ey = int.Parse(a[2]), ew = int.Parse(a[3]), eh = int.Parse(a[4]);
        int cycles = int.Parse(a[5]);
        int mode = int.Parse(a[6]);      // 0=immediate 1=fixed delay 2=stability
        int delayMs = int.Parse(a[7]);
        string outPath = a[8];
        Target = new IntPtr(hwnd);

        var t = new StringBuilder(300); G.GetWindowTextW(Target, t, 300);
        Hdr("hwnd=" + hwnd + "  expected=" + ex + "," + ey + " " + ew + "x" + eh
            + "  cycles=" + cycles + "  mode=" + mode + (mode == 1 ? "(delay=" + delayMs + "ms)" : "")
            + "  win=" + t.ToString());
        Hdr("cycle,driftAtRestore,guardrailApplied,guardMs,rectAtRestore,rectAfterGuard,finalWidth,reDrift,corrections");

        for (int c = 1; c <= cycles; c++) {
            // 모드 3에서는 이 사각형이 "사용자가 정한 크기"를 겸한다.
            // 모드 0/2에서는 저장된 zone 기대값으로 쓰인다.
            G.SetWindowPos(Target, IntPtr.Zero, ex, ey, ew, eh, G.SWP_NOZORDER | G.SWP_NOACTIVATE);
            System.Threading.Thread.Sleep(700);

            // 최소화 직전 실제 geometry를 기억한다. zone 저장소를 쓰지
            // 않으므로, 사용자가 resize한 값이 그대로 보존 대상이 된다.
            G.RECT baseline = G.Rect(Target);
            int bx = baseline.L, by = baseline.T;
            int bw = baseline.R - baseline.L, bh = baseline.B - baseline.T;

            G.ShowWindow(Target, 6);                 // SW_MINIMIZE
            System.Threading.Thread.Sleep(420);
            G.ShowWindow(Target, 9);                 // SW_RESTORE
            long t0 = Clock.ElapsedMilliseconds;

            G.RECT r0 = G.Rect(Target);
            int w0 = r0.R - r0.L;
            int expW = (mode == 3) ? bw : ew;
            int expH = (mode == 3) ? bh : eh;
            int expX = (mode == 3) ? bx : ex;
            int expY = (mode == 3) ? by : ey;
            bool drift = (r0.L != expX || r0.T != expY || w0 != expW || (r0.B - r0.T) != expH);

            // guardrail, timed per the chosen mode
            long gStart = Clock.ElapsedMilliseconds;
            int waitMs = 0;
            if (mode == 1) { System.Threading.Thread.Sleep(delayMs); waitMs = delayMs; }
            else if (mode == 2) {
                G.RECT prev = G.Rect(Target); int stable = 0; int spin = 0;
                while (stable < 2 && spin < 60) {
                    System.Threading.Thread.Sleep(5); spin++;
                    G.RECT cur = G.Rect(Target);
                    if (cur.L == prev.L && cur.T == prev.T && cur.R == prev.R && cur.B == prev.B) stable++;
                    else { stable = 0; prev = cur; }
                }
                waitMs = (int)(Clock.ElapsedMilliseconds - gStart);
            }
            G.RECT rg = G.Rect(Target);
            bool applied = false;
            if (rg.L != expX || rg.T != expY || rg.R - rg.L != expW || rg.B - rg.T != expH) {
                G.SetWindowPos(Target, IntPtr.Zero, expX, expY, expW, expH, G.SWP_NOZORDER | G.SWP_NOACTIVATE);
                applied = true;
            }
            G.RECT ra = G.Rect(Target);
            long gEnd = Clock.ElapsedMilliseconds;
            bool ok = (ra.L == expX && ra.T == expY && ra.R - ra.L == expW && ra.B - ra.T == expH);

            // re-drift: does Chrome put its own size back afterwards
            bool reDrift = false; int finalW = 0;
            for (int i = 0; i < 20; i++) {
                System.Threading.Thread.Sleep(100);
                G.RECT rf = G.Rect(Target);
                finalW = rf.R - rf.L;
                if (rf.L != expX || rf.T != expY || rf.R - rf.L != expW || rf.B - rf.T != expH) { reDrift = true; break; }
            }
            L.Add(string.Format(CultureInfo.InvariantCulture,
                "{0},{1},{2},{3},\"{4}\",\"{5}\",{6},{7},{8}",
                c, drift, applied, gEnd - gStart, G.Fmt(r0), G.Fmt(ra), finalW, reDrift, ok ? 0 : 1));
            Say("cycle " + c + " drift=" + drift + " applied=" + applied + " guardMs=" + (gEnd - gStart)
                + " reDrift=" + reDrift + " finalW=" + finalW + " expected=" + expX + "," + expY + " " + expW + "x" + expH);
        }
        File.WriteAllLines(outPath, L);
        Console.WriteLine("done cycles=" + cycles + " -> " + outPath);
    }
}
