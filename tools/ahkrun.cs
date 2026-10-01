using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// ahkrun: two jobs this build keeps getting wrong by hand.
//
//   check <script.ahk>
//       Compiles with Ahk2Exe and reports what it said. Nothing is left
//       running, so a syntax error surfaces here rather than as a dialog
//       nobody is watching for.
//
//   run <script.ahk> [seconds]
//       Runs the script and reads its error dialog if one appears.
//
// AutoHotkey is killed first in both modes. #SingleInstance Force means
// a new launch terminates an older one, so leaving one running makes the
// new script die before it writes a single line, which looks exactly
// like a script that silently fails to log anything.

class Program
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }

    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr wp, StringBuilder lp, uint flags, uint timeout, out IntPtr result);

    const string AHK = @"C:\Program Files\AutoHotkey\v2\AutoHotkey.exe";
    const string AHK64 = @"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe";
    const string A2E = @"C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe";
    const string BASE = @"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe";
    const uint WM_GETTEXT = 0x000D;
    const uint WM_GETTEXTLENGTH = 0x000E;

    static string Cls(IntPtr h)
    {
        var s = new StringBuilder(256);
        GetClassNameW(h, s, 256);
        return s.ToString();
    }

    // GetWindowText does not cross into a dialog owned by another
    // process, which is why the message body came back empty. WM_GETTEXT
    // is sent instead, with a timeout so a hung window cannot stall this.
    static string MsgText(IntPtr h)
    {
        IntPtr res;
        var len = new StringBuilder(8);
        SendMessageTimeoutW(h, WM_GETTEXTLENGTH, IntPtr.Zero, len, 2, 2000, out res);
        int n = 0;
        int.TryParse(len.ToString(), out n);
        if (n <= 0) n = 4096;
        if (n > 16000) n = 16000;
        var sb = new StringBuilder(n + 2);
        if (SendMessageTimeoutW(h, WM_GETTEXT, new IntPtr(sb.Capacity), sb, 2, 2000, out res) == IntPtr.Zero)
            return "";
        return sb.ToString();
    }

    static void KillStray()
    {
        string[] names = { "AutoHotkey", "AutoHotkeyU64" };
        foreach (var nm in names)
        {
            foreach (var p in Process.GetProcessesByName(nm))
            {
                try { p.Kill(); p.WaitForExit(3000); } catch { }
            }
        }
        System.Threading.Thread.Sleep(600);
    }

    static List<IntPtr> WindowsOf(int pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) =>
        {
            uint wp;
            GetWindowThreadProcessId(h, out wp);
            if ((int)wp == pid) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static void DumpWindow(IntPtr h, StringBuilder o)
    {
        o.AppendLine("  window class='" + Cls(h) + "' visible=" + IsWindowVisible(h));
        string t = MsgText(h);
        if (t.Length > 0) o.AppendLine("    title: " + t);

        var kids = new List<IntPtr>();
        EnumChildWindows(h, (c, l) => { kids.Add(c); return true; }, IntPtr.Zero);
        foreach (var c in kids)
        {
            string cc = Cls(c);
            if (cc == "Button") continue;
            string ct = MsgText(c);
            if (ct.Trim().Length == 0) continue;
            o.AppendLine("    [" + cc + "] " + ct);
        }
    }

    static int Check(string script)
    {
        if (!File.Exists(A2E)) { Console.WriteLine("NO_COMPILER " + A2E); return 3; }
        string tmp = Path.Combine(Path.GetTempPath(), "ahkrun_check.exe");
        try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }

        var psi = new ProcessStartInfo();
        psi.FileName = A2E;
        psi.Arguments = "/in \"" + script + "\" /out \"" + tmp + "\" /base \"" + BASE + "\" /silent verbose";
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;

        using (var p = Process.Start(psi))
        {
            string so = p.StandardOutput.ReadToEnd();
            string se = p.StandardError.ReadToEnd();
            p.WaitForExit(60000);
            if (so.Trim().Length > 0) Console.WriteLine("stdout: " + so.Trim());
            if (se.Trim().Length > 0) Console.WriteLine("stderr: " + se.Trim());
            if (se.Contains("syntax error") || se.Contains("Error:")) { Console.WriteLine("RESULT: syntax error"); return 1; }
            if (!File.Exists(tmp)) { Console.WriteLine("RESULT: no exe produced"); return 1; }
            try { File.Delete(tmp); } catch { }
            Console.WriteLine("RESULT: clean");
            return 0;
        }
    }

    static int Run(string script, int seconds)
    {
        if (!File.Exists(AHK)) { Console.WriteLine("NO_AHK"); return 3; }
        KillStray();

        var psi = new ProcessStartInfo();
        psi.FileName = File.Exists(AHK) ? AHK : AHK64;
        psi.Arguments = "\"" + script + "\"";
        psi.UseShellExecute = false;

        Process proc = Process.Start(psi);
        if (proc == null) { Console.WriteLine("START_FAILED"); return 2; }
        int pid = proc.Id;

        var sb = new StringBuilder();
        bool dialog = false;
        var end = DateTime.Now.AddSeconds(seconds);

        while (DateTime.Now < end)
        {
            System.Threading.Thread.Sleep(250);
            try { if (proc.HasExited) { sb.AppendLine("exited early code=" + proc.ExitCode); break; } }
            catch { break; }

            foreach (var h in WindowsOf(pid))
            {
                string c = Cls(h);
                bool isDialog = c == "#32770" || c == "AutoHotkey" || c == "AutoHotkey2";
                if (!isDialog) continue;
                sb.AppendLine("DIALOG:");
                DumpWindow(h, sb);
                dialog = true;
            }
            if (dialog) break;
        }

        try { if (!proc.HasExited) proc.Kill(); } catch { }
        try { proc.WaitForExit(3000); } catch { }

        Console.Write(sb.ToString());
        if (dialog) { Console.WriteLine("RESULT: dialog"); return 1; }
        Console.WriteLine("RESULT: clean, no dialog in " + seconds + "s");
        return 0;
    }

    static int Main(string[] args)
    {
        if (args.Length < 2) { Console.WriteLine("usage: ahkrun check|run <script.ahk> [seconds]"); return 3; }
        if (args[0] == "check") return Check(args[1]);
        if (args[0] == "run")
        {
            int s = 6;
            if (args.Length > 2) int.TryParse(args[2], out s);
            return Run(args[1], s);
        }
        Console.WriteLine("unknown mode " + args[0]);
        return 3;
    }
}
