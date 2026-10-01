using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Samples a screen region fast enough to catch a black flash, and reports
// how long the region stayed dark. A minimize and restore normally shows
// the desktop for a moment; what we are looking for is the *window's* own
// area going black, which is a repaint that never finished.

class Probe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);

    static int Main(string[] args)
    {
        int hwnd = int.Parse(args[0]);
        int cycles = args.Length > 1 ? int.Parse(args[1]) : 3;
        IntPtr h = new IntPtr(hwnd);

        Console.WriteLine("hwnd=" + hwnd);

        for (int c = 1; c <= cycles; c++)
        {
            // Make sure it is up before measuring, and take the sample
            // region from the rectangle it actually has now rather than
            // from whatever it had when the program started. A window
            // left minimised reports -32000,-32000 and sampling that
            // measures nothing.
            if (IsIconic(h)) ShowWindow(h, 9);
            System.Threading.Thread.Sleep(700);
            RECT wr;
            if (!GetWindowRect(h, out wr)) { Console.WriteLine("  cycle " + c + ": window gone"); return 1; }
            int bw = wr.R - wr.L, bh = wr.B - wr.T;
            // A block in the middle of the window, avoiding the very edge.
            int sx = wr.L + bw / 4, sy = wr.T + bh / 4;
            int sw = Math.Max(8, bw / 2), sh = Math.Max(8, bh / 2);

            // dark run bookkeeping
            int darkStart = -1, darkMs = 0, frames = 0;
            var sw_ = Stopwatch.StartNew();
            long t0 = sw_.ElapsedMilliseconds;
            // restore
            ShowWindow(h, 9);
            while (sw_.ElapsedMilliseconds - t0 < 2500)
            {
                int lum = Lum(sx, sy, sw, sh);
                frames++;
                if (lum < 12)
                {
                    if (darkStart < 0) darkStart = (int)(sw_.ElapsedMilliseconds - t0);
                }
                else
                {
                    if (darkStart >= 0)
                    {
                        int d = (int)(sw_.ElapsedMilliseconds - t0) - darkStart;
                        if (d > darkMs) darkMs = d;
                        darkStart = -1;
                    }
                }
                System.Threading.Thread.Sleep(2);
            }
            if (darkStart >= 0)
            {
                int d = (int)(sw_.ElapsedMilliseconds - t0) - darkStart;
                if (d > darkMs) darkMs = d;
            }
            RECT endr; GetWindowRect(h, out endr);
            Console.WriteLine("  cycle " + c + ": rect=" + endr.L + "," + endr.T
                + " " + (endr.R - endr.L) + "x" + (endr.B - endr.T)
                + " frames=" + frames + " darkestRunMs=" + darkMs
                + (darkMs > 150 ? "   <== BLACK FLASH" : ""));
            System.Threading.Thread.Sleep(600);
            ShowWindow(h, 6);   // minimize
            System.Threading.Thread.Sleep(1200);
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
