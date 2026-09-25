using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace PingGadget
{
    enum AstrillOffResult
    {
        Untouched, // Astrill was off, not running, or didn't respond: leave it as it is
        Toggled,   // switched off with its ON/OFF switch; switch it back on
        Closed     // switch not found while connected, so the app was closed; start it again
    }

    // Astrill has no API, so we press the big ON/OFF switch in its window by posting
    // mouse messages to it. This works while the window is visible, hidden in the tray,
    // or minimized. Rule: never touch Astrill unless we are sure it is ON.
    static class Astrill
    {
        // Positions inside Astrill's main panel, as fractions of its size.
        const double SwitchX = 0.50, SwitchY = 0.257;
        const double KnobOnX = 0.79, KnobOffX = 0.25;

        public static AstrillOffResult TurnOff()
        {
            Process proc = FindProcess();
            if (proc == null) return AstrillOffResult.Untouched;

            using (proc)
            {
                IntPtr panel = FindSwitchPanel(proc.Id);

                // The switch picture is authoritative when we can see it; when the window is
                // hidden or minimized it can't be captured, so fall back to the VPN's routes.
                bool? shown = panel != IntPtr.Zero ? ReadSwitch(panel) : null;
                bool isOn = shown.HasValue ? shown.Value : NetworkManager.IsVpnRouted();
                if (!isOn) return AstrillOffResult.Untouched;

                if (panel == IntPtr.Zero)
                {
                    Kill(proc);
                    return AstrillOffResult.Closed;
                }

                Click(panel);
                bool off = WaitUntil(delegate
                {
                    bool? s = ReadSwitch(panel);
                    return (!s.HasValue || !s.Value) && !NetworkManager.IsVpnRouted();
                }, 8000);

                // If the click didn't register, don't click again later: that would turn it OFF.
                if (!off) return AstrillOffResult.Untouched;
                Thread.Sleep(300); // let the tunnel finish tearing down
                return AstrillOffResult.Toggled;
            }
        }

        public static void TurnOn(AstrillOffResult previous, string exePath)
        {
            if (previous == AstrillOffResult.Closed)
            {
                Start(exePath);
                WaitForVpn();
                return;
            }
            if (previous != AstrillOffResult.Toggled) return;

            Process proc = FindProcess();
            if (proc == null)
            {
                Start(exePath);
                WaitForVpn();
                return;
            }

            using (proc)
            {
                IntPtr panel = FindSwitchPanel(proc.Id);
                if (panel == IntPtr.Zero)
                {
                    Kill(proc);
                    Start(exePath);
                    WaitForVpn();
                    return;
                }

                Thread.Sleep(700); // Astrill may ignore clicks while still disconnecting
                if (ReadSwitch(panel) != true) Click(panel);
                Thread.Sleep(1200);
                if (ReadSwitch(panel) == false) Click(panel); // visibly still OFF: the click was ignored
                WaitForVpn();
            }
        }

        // Reconnecting takes 3-7 s typically, but 30+ s when Astrill falls back to another
        // protocol; wait so callers don't judge the new router before the VPN is back.
        static void WaitForVpn()
        {
            WaitUntil(NetworkManager.IsVpnRouted, 45000);
        }

        static Process FindProcess()
        {
            Process[] procs = Process.GetProcessesByName("astrill");
            for (int i = 1; i < procs.Length; i++) procs[i].Dispose();
            return procs.Length > 0 ? procs[0] : null;
        }

        static void Kill(Process proc)
        {
            try
            {
                proc.Kill();
                proc.WaitForExit(5000);
            }
            catch (Win32Exception) { }
            catch (InvalidOperationException) { }
            Thread.Sleep(1000); // give the Astrill service a moment to drop the tunnel
        }

        static void Start(string path)
        {
            if (!File.Exists(path))
                throw new FileNotFoundException("Astrill was not found at " + path + ".");
            Process.Start(new ProcessStartInfo(path, "/autostart")
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(path)
            }).Dispose();
        }

        // The switch lives in the tallest visible, childless panel of the "Astrill" main window
        // (the login panel shares its bounds but is hidden and holds the edit boxes). Height is
        // used rather than area because a minimized window squeezes its panels to zero width.
        static IntPtr FindSwitchPanel(int pid)
        {
            IntPtr best = IntPtr.Zero;
            int bestHeight = 99;
            EnumWindowsProc callback = delegate(IntPtr top, IntPtr lParam)
            {
                uint windowPid;
                GetWindowThreadProcessId(top, out windowPid);
                if (windowPid != pid || GetClass(top) != "Window" || GetText(top) != "Astrill") return true;

                for (IntPtr child = GetWindow(top, GW_CHILD); child != IntPtr.Zero; child = GetWindow(child, GW_HWNDNEXT))
                {
                    if ((GetWindowLong(child, GWL_STYLE) & WS_VISIBLE) == 0) continue;
                    if (GetWindow(child, GW_CHILD) != IntPtr.Zero) continue;
                    RECT r;
                    GetClientRect(child, out r);
                    if (r.Bottom > bestHeight)
                    {
                        best = child;
                        bestHeight = r.Bottom;
                    }
                }
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return best;
        }

        // The panel's layout size. While Astrill is minimized the panel reports zero width,
        // so use the main window's restored width instead (the panel spans the full width).
        static Size PanelSize(IntPtr panel)
        {
            RECT r;
            GetClientRect(panel, out r);
            int width = r.Right;
            if (width <= 0)
            {
                var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf(typeof(WINDOWPLACEMENT)) };
                if (GetWindowPlacement(GetParent(panel), ref wp))
                    width = wp.rcNormalPosition.Right - wp.rcNormalPosition.Left;
            }
            return new Size(width, r.Bottom);
        }

        // Reads the switch from the panel's pixels: dark knob on the right = ON, orange on the
        // left = OFF. Returns null when it can't tell (hidden windows render black, minimized
        // ones not at all).
        static bool? ReadSwitch(IntPtr panel)
        {
            RECT r;
            GetClientRect(panel, out r);
            if (r.Right <= 0 || r.Bottom <= 0) return null;

            using (var bmp = new Bitmap(r.Right, r.Bottom))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    IntPtr hdc = g.GetHdc();
                    bool printed = PrintWindow(panel, hdc, PW_RENDERFULLCONTENT);
                    g.ReleaseHdc(hdc);
                    if (!printed) return null;
                }

                int y = (int)(r.Bottom * SwitchY);
                Color on = bmp.GetPixel((int)(r.Right * KnobOnX), y);
                Color off = bmp.GetPixel((int)(r.Right * KnobOffX), y);
                int onMax = Math.Max(on.R, Math.Max(on.G, on.B));
                if (onMax > 0x10 && onMax < 0x70) return true;
                if (off.R > 0xA0 && off.G < 0x80 && off.B < 0x50) return false;
                return null;
            }
        }

        static void Click(IntPtr panel)
        {
            Size size = PanelSize(panel);
            int x = (int)(size.Width * SwitchX), y = (int)(size.Height * SwitchY);
            IntPtr lParam = (IntPtr)((y << 16) | (x & 0xFFFF));
            PostMessage(panel, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, lParam);
            Thread.Sleep(80);
            PostMessage(panel, WM_LBUTTONUP, IntPtr.Zero, lParam);
        }

        static bool WaitUntil(Func<bool> condition, int timeoutMs)
        {
            var clock = Stopwatch.StartNew();
            while (!condition())
            {
                if (clock.ElapsedMilliseconds >= timeoutMs) return false;
                Thread.Sleep(200);
            }
            return true;
        }

        static string GetClass(IntPtr hwnd)
        {
            var sb = new StringBuilder(64);
            GetClassName(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        static string GetText(IntPtr hwnd)
        {
            var sb = new StringBuilder(64);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        const uint WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202;
        const int MK_LBUTTON = 1;
        const uint GW_CHILD = 5, GW_HWNDNEXT = 2;
        const int GWL_STYLE = -16;
        const int WS_VISIBLE = 0x10000000;
        const uint PW_RENDERFULLCONTENT = 2;

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct WINDOWPLACEMENT
        {
            public int length, flags, showCmd;
            public Point ptMinPosition, ptMaxPosition;
            public RECT rcNormalPosition;
        }

        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hwnd, ref WINDOWPLACEMENT placement);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    }
}
