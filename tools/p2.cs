using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Starts sampling, then minimizes and restores the window while sampling
// continues, and reports the longest run of black frames. The point is to
// catch the flash at the moment of restore rather than after it, and to
// see whether it happens with or without the manager running.

class P2
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);

    static int Main(string[] args)
    {
        int hwnd = int.Parse(args[0]);
        int cycles = args.Length > 1 ? int.Parse(args[1]) : 5;
        IntPtr h = new IntPtr(hwnd);

        for (int c = 1; c <= cycles; c++)
        {
            if (IsIconic(h)) ShowWindow(h, 9);
            System.Threading.Thread.Sleep(1500);
            RECT wr;
            if (!GetWindowRect(h, out wr)) { Console.WriteLine("gone"); return 1; }
            int bw = wr.R - wr.L, bh = wr.B - wr.T;
            int sx = wr.L + bw / 4, sy = wr.T + bh / 4;
            int sw = Math.Max(8, bw / 2), sh = Math.Max(8, bh / 2);
            Console.WriteLine("  cycle " + c + " start rect=" + wr.L + "," + wr.T + " " + bw + "x" + bh);

            int darkStart = -1, darkMs = 0, frames = 0, firstDark = -1;
            var sw2 = Stopwatch.StartNew();
            // This is the restore. Sampling is already running.
            ShowWindow(h, 6);
            System.Threading.Thread.Sleep(900);
            ShowWindow(h, 9);
            long t0 = sw2.ElapsedMilliseconds;
            while (sw2.ElapsedMilliseconds - t0 < 3000)
            {
                int lum = Lum(sx, sy, sw, sh);
                frames++;
                int at = (int)(sw2.ElapsedMilliseconds - t0);
                if (lum < 12)
                {
                    if (darkStart < 0) { darkStart = at; if (firstDark < 0) firstDark = at; }
                }
                else if (darkStart >= 0)
                {
                    int d = at - darkStart;
                    if (d > darkMs) darkMs = d;
                    darkStart = -1;
                }
                System.Threading.Thread.Sleep(2);
            }
            if (darkStart >= 0)
            {
                int d = (int)(sw2.ElapsedMilliseconds - t0) - darkStart;
                if (d > darkMs) darkMs = d;
            }
            RECT e; GetWindowRect(h, out e);
            Console.WriteLine("    -> rect=" + e.L + "," + e.T + " " + (e.R - e.L) + "x" + (e.B - e.T)
                + " frames=" + frames + " darkestRunMs=" + darkMs
                + " firstDarkAtMs=" + firstDark
                + (darkMs > 120 ? "   <== BLACK FLASH" : ""));
            System.Threading.Thread.Sleep(800);
        }
        return 0;
    }

    static int Lum(int x, int y, int w, int h)
    {
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int sum = 0, n = 0, stride = d.Stride;
            unsafe
            {
                byte* p = (byte*)d.Scan0;
                for (int row = 0; row < h; row += 2)
                {
                    byte* q = p + row * stride;
                    for (int col = 0; col < w; col += 2)
                    {
                        int b = q[col * 4], g2 = q[col * 4 + 1], r = q[col * 4 + 2];
                        sum += (b * 29 + g2 * 150 + r * 77) >> 8;
                        n++;
                    }
                }
            }
            bmp.UnlockBits(d);
            return n > 0 ? sum / n : 255;
        }
    }
}
