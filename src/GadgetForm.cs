using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace PingGadget
{
    class GadgetForm : Form
    {
        const string Gap = "  ";
        const TextFormatFlags TextFlags = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;

        AppSettings settings;
        readonly ComboBox routerBox;
        readonly ContextMenuStrip menu;
        readonly System.Windows.Forms.Timer timer;
        readonly Ping ping = new Ping();
        SettingsForm settingsForm;

        bool pingBusy;
        string pingText, upText, downText;

        NetworkInterface nic;
        volatile bool nicStale = true;
        long lastSent, lastReceived;
        readonly Stopwatch sampleClock = new Stopwatch();

        bool suppressRouterEvent;
        bool switching;
        bool closeAfterSwitch;
        int switchGeneration;
        int lastAutoIndex = -1;
        readonly Stopwatch failClock = new Stopwatch();
        Rectangle textRect;

        public GadgetForm(AppSettings settings)
        {
            this.settings = settings;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            DoubleBuffered = true;

            menu = new ContextMenuStrip();
            menu.Items.Add("Settings", null, delegate { ShowSettings(); });
            menu.Items.Add("Close", null, delegate { Close(); });
            ContextMenuStrip = menu;

            routerBox = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList,
                DrawMode = DrawMode.OwnerDrawFixed,
                FlatStyle = FlatStyle.Flat,
                TabStop = false,
                ContextMenuStrip = menu
            };
            routerBox.DrawItem += RouterBox_DrawItem;
            routerBox.SelectedIndexChanged += RouterBox_SelectedIndexChanged;
            Controls.Add(routerBox);

            timer = new System.Windows.Forms.Timer { Interval = 1000 };
            timer.Tick += Timer_Tick;

            NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;

            ResetReadings();
            ApplySettings(settings);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                const int WS_EX_TOOLWINDOW = 0x80;
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOOLWINDOW; // keep out of Alt+Tab
                return cp;
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            PlaceOnScreen();
            SyncRouterSelection();
            timer.Start();
            Timer_Tick(this, EventArgs.Empty);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // Quitting mid-switch could leave Astrill OFF; finish (or time out) first. Windows
            // shutdown can't be delayed, so only defer a close the user asked for.
            if (switching && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                closeAfterSwitch = true;
                pingText = "Closing after switch...";
                Invalidate();
            }
            base.OnFormClosing(e);
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
            timer.Stop();
            SavePosition();
            base.OnFormClosed(e);
        }

        public void ApplySettings(AppSettings s)
        {
            bool targetChanged = s.PingTarget != settings.PingTarget;
            // The window may have been dragged while the settings dialog was open.
            s.X = settings.X;
            s.Y = settings.Y;
            settings = s;

            Font old = Font;
            Font = new Font("Segoe UI", s.FontSize, FontStyle.Regular, GraphicsUnit.Point);
            if (old != null && old != DefaultFont) old.Dispose();

            ForeColor = s.ForeColor;
            BackColor = s.BackColor;
            Opacity = Math.Max(20, Math.Min(100, s.Opacity)) / 100.0;

            routerBox.Font = Font;
            routerBox.BackColor = s.BackColor;
            routerBox.ForeColor = s.ForeColor;
            routerBox.ItemHeight = TextRenderer.MeasureText("Ag", Font, Size.Empty, TextFlags).Height + 4;

            suppressRouterEvent = true;
            routerBox.Items.Clear();
            foreach (RouterInfo r in s.Routers) routerBox.Items.Add(r);
            suppressRouterEvent = false;

            if (targetChanged) pingText = "Time=--- TTL=---";
            nicStale = true;
            lastAutoIndex = -1;
            failClock.Reset();

            LayoutGadget();
            if (IsHandleCreated)
            {
                PlaceOnScreen();
                SyncRouterSelection();
                settings.Save();
            }
            Invalidate();
        }

        // ---------- Layout and painting ----------

        List<string> BuildLines(string pingPart, string upPart, string downPart)
        {
            var parts = new List<string>();
            if (settings.ShowPing) parts.Add(pingPart);
            if (settings.ShowUpload) parts.Add(upPart);
            if (settings.ShowDownload) parts.Add(downPart);

            var lines = new List<string>();
            if (parts.Count == 3)
            {
                lines.Add(parts[0]);
                lines.Add(parts[1] + Gap + parts[2]);
            }
            else if (parts.Count > 0)
            {
                lines.Add(string.Join(Gap, parts));
            }
            return lines;
        }

        void LayoutGadget()
        {
            int pad = Scale(6);
            int gap = Scale(10);

            // Size the text area from worst-case strings so the window doesn't jitter.
            List<string> templates = BuildLines("Time=9999ms TTL=999", "Up=999.9Mbps", "Down=999.9Mbps");
            int lineHeight = TextRenderer.MeasureText("Ag", Font, Size.Empty, TextFlags).Height;
            int textW = 0;
            foreach (string t in templates)
                textW = Math.Max(textW, TextRenderer.MeasureText(t, Font, Size.Empty, TextFlags).Width);
            int textH = templates.Count * lineHeight;

            bool hasRouters = routerBox.Items.Count > 0;
            int comboW = 0;
            if (hasRouters)
            {
                foreach (object item in routerBox.Items)
                    comboW = Math.Max(comboW, TextRenderer.MeasureText(item.ToString(), Font, Size.Empty, TextFlags).Width);
                comboW += SystemInformation.VerticalScrollBarWidth + Scale(10);
                routerBox.DropDownWidth = comboW;
            }
            routerBox.Visible = hasRouters;

            int innerH = Math.Max(textH, hasRouters ? routerBox.Height : 0);
            if (innerH == 0) innerH = lineHeight;
            textRect = new Rectangle(pad, pad + (innerH - textH) / 2, textW, textH);

            int x = pad + (templates.Count > 0 ? textW : 0);
            if (templates.Count > 0 && hasRouters) x += gap;
            if (hasRouters)
                routerBox.SetBounds(x, pad + (innerH - routerBox.Height) / 2, comboW, routerBox.Height);

            ClientSize = new Size(Math.Max(x + comboW + pad, Scale(40)), innerH + 2 * pad);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            List<string> lines = BuildLines(pingText, upText, downText);
            if (lines.Count == 0) return;
            int lineHeight = textRect.Height / lines.Count;
            for (int i = 0; i < lines.Count; i++)
            {
                var r = new Rectangle(textRect.X, textRect.Y + i * lineHeight, textRect.Width, lineHeight);
                TextRenderer.DrawText(e.Graphics, lines[i], Font, r, ForeColor, TextFlags | TextFormatFlags.EndEllipsis);
            }
        }

        int Scale(int px)
        {
            return (int)Math.Round(px * DeviceDpi / 96.0);
        }

        // ---------- Dragging and position ----------

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            ReleaseCapture();
            SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero); // returns when the drag ends
            SavePosition();
        }

        void PlaceOnScreen()
        {
            int margin = Scale(12);
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            var pos = new Point(settings.X, settings.Y);
            if (settings.X == int.MinValue || !IsOnAnyScreen(new Rectangle(pos, Size)))
                pos = new Point(wa.Right - Width - margin, wa.Top + margin);
            Location = pos;
        }

        static bool IsOnAnyScreen(Rectangle r)
        {
            foreach (Screen s in Screen.AllScreens)
                if (s.WorkingArea.IntersectsWith(r)) return true;
            return false;
        }

        void SavePosition()
        {
            settings.X = Left;
            settings.Y = Top;
            try { settings.Save(); }
            catch (Exception) { /* position isn't worth an error dialog */ }
        }

        // ---------- Measurements ----------

        void ResetReadings()
        {
            pingText = "Time=--- TTL=---";
            upText = "Up=---";
            downText = "Down=---";
        }

        async void Timer_Tick(object sender, EventArgs e)
        {
            if (settings.ShowUpload || settings.ShowDownload) UpdateSpeed();
            Invalidate();

            // Auto-switch needs ping results even when ping isn't displayed.
            if (!(settings.ShowPing || settings.AutoSwitch) || pingBusy || switching) return;
            pingBusy = true;
            int generation = switchGeneration;
            bool ok = false;
            string text;
            try
            {
                PingReply reply = await ping.SendPingAsync(settings.PingTarget, 2000);
                ok = reply.Status == IPStatus.Success;
                if (ok)
                    text = "Time=" + reply.RoundtripTime + "ms TTL=" + (reply.Options != null ? reply.Options.Ttl.ToString() : "-");
                else if (reply.Status == IPStatus.TimedOut)
                    text = "Time=timeout";
                else
                    text = "Time=" + reply.Status;
            }
            catch (PingException)
            {
                text = "Time=no host";
            }
            catch (Exception)
            {
                text = "Time=error";
            }
            finally
            {
                pingBusy = false;
            }

            // Ignore replies to pings sent before or during a router switch.
            if (switching || generation != switchGeneration) return;
            pingText = text;
            OnPingResult(ok);
            Invalidate();
        }

        void OnPingResult(bool ok)
        {
            if (ok)
            {
                failClock.Reset();
                lastAutoIndex = -1;
                return;
            }
            if (!failClock.IsRunning) failClock.Start();

            if (settings.AutoSwitch && settings.Routers.Count > 1 &&
                failClock.Elapsed.TotalSeconds >= settings.AutoSwitchSeconds)
            {
                // Continue from the last router we tried, so a router that fails to
                // switch doesn't make us retry the same one forever.
                int from = lastAutoIndex >= 0 ? lastAutoIndex : routerBox.SelectedIndex;
                lastAutoIndex = (from + 1) % settings.Routers.Count;
                SwitchTo(lastAutoIndex, false);
            }
        }

        void UpdateSpeed()
        {
            if (nicStale)
            {
                nicStale = false;
                nic = NetworkManager.FindAdapter(settings.Routers);
                sampleClock.Reset();
            }
            if (nic == null)
            {
                upText = "Up=---";
                downText = "Down=---";
                return;
            }

            IPInterfaceStatistics stats;
            try
            {
                stats = nic.GetIPStatistics();
            }
            catch (NetworkInformationException)
            {
                nicStale = true;
                return;
            }

            if (sampleClock.IsRunning)
            {
                double secs = sampleClock.Elapsed.TotalSeconds;
                if (secs > 0)
                {
                    double up = Math.Max(0, stats.BytesSent - lastSent) * 8 / secs / 1e6;
                    double down = Math.Max(0, stats.BytesReceived - lastReceived) * 8 / secs / 1e6;
                    upText = "Up=" + FormatMbps(up) + "Mbps";
                    downText = "Down=" + FormatMbps(down) + "Mbps";
                }
            }
            lastSent = stats.BytesSent;
            lastReceived = stats.BytesReceived;
            sampleClock.Restart();
        }

        static string FormatMbps(double v)
        {
            return v >= 100 ? v.ToString("F0") : v.ToString("F1");
        }

        void OnNetworkAddressChanged(object sender, EventArgs e)
        {
            nicStale = true;
            // Raised on a pool thread; the window may be closing, and an exception here would crash the app.
            try
            {
                if (IsHandleCreated && !IsDisposed) BeginInvoke(new Action(SyncRouterSelection));
            }
            catch (InvalidOperationException) { }
        }

        // ---------- Router selection ----------

        void SyncRouterSelection()
        {
            if (switching) return;
            int index = -1;
            NetworkInterface n = NetworkManager.FindAdapter(settings.Routers);
            IPAddress gw = n != null ? NetworkManager.GetGateway(n) : null;
            if (gw != null)
            {
                for (int i = 0; i < settings.Routers.Count; i++)
                {
                    IPAddress ip;
                    if (IPAddress.TryParse(settings.Routers[i].Ip, out ip) && ip.Equals(gw)) { index = i; break; }
                }
            }
            suppressRouterEvent = true;
            routerBox.SelectedIndex = index;
            suppressRouterEvent = false;
        }

        void RouterBox_SelectedIndexChanged(object sender, EventArgs e)
        {
            if (suppressRouterEvent || routerBox.SelectedIndex < 0) return;
            ActiveControl = null;
            lastAutoIndex = -1;
            SwitchTo(routerBox.SelectedIndex, true);
        }

        // interactive = picked by the user (show errors); otherwise an automatic switch.
        async void SwitchTo(int index, bool interactive)
        {
            if (switching || index < 0 || index >= settings.Routers.Count) return;
            RouterInfo router = settings.Routers[index];

            IPAddress ip;
            if (!IPAddress.TryParse(router.Ip, out ip))
            {
                if (interactive)
                    MessageBox.Show(this, "Invalid IP address: " + router.Ip, "Ping Gadget", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                SyncRouterSelection();
                return;
            }

            switching = true;
            suppressRouterEvent = true;
            routerBox.SelectedIndex = index;
            suppressRouterEvent = false;
            routerBox.Enabled = false;
            pingText = "Switching...";
            Invalidate();

            // The worker stops waiting for the VPN when the token fires. The extra grace period on
            // the UI side covers a step that never returns (e.g. Windows hanging on the gateway
            // change); the worker is then abandoned and later switches wait for it to finish.
            AppSettings current = settings;
            int timeoutMs = current.SwitchTimeoutSeconds * 1000;
            var cancel = new CancellationTokenSource(timeoutMs);
            Task<bool> work = Task.Run(() => NetworkManager.SwitchRouter(ip, current, cancel.Token), cancel.Token);
            string status = null, error = null;
            if (await Task.WhenAny(work, Task.Delay(timeoutMs + 5000)) != work)
            {
                cancel.Cancel();
                Task abandoned = work.ContinueWith(t => { var ignored = t.Exception; cancel.Dispose(); });
                status = "Switch timed out";
            }
            else
            {
                cancel.Dispose();
                if (work.IsFaulted)
                {
                    Exception ex = work.Exception.GetBaseException();
                    status = "Switch failed";
                    error = ex.Message;
                }
                else if (work.IsCanceled)
                    status = "Switch timed out";
                else if (!work.Result)
                    status = "VPN not reconnected";
            }

            switching = false;
            switchGeneration++;
            failClock.Reset(); // give the new router the full wait before judging it
            routerBox.Enabled = true;
            nicStale = true;
            pingText = status ?? "Time=--- TTL=---"; // replaced by the next ping result
            SyncRouterSelection();
            Invalidate();

            if (closeAfterSwitch)
            {
                Close();
                return;
            }
            // Only after the gadget is usable again: the dialog blocks until it is dismissed.
            if (error != null && interactive)
                MessageBox.Show(this, error, "Switch router failed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        void RouterBox_DrawItem(object sender, DrawItemEventArgs e)
        {
            bool highlighted = (e.State & DrawItemState.Selected) != 0 && (e.State & DrawItemState.ComboBoxEdit) == 0;
            Color back = highlighted ? settings.ForeColor : settings.BackColor;
            Color fore = highlighted ? settings.BackColor : settings.ForeColor;
            using (var brush = new SolidBrush(back)) e.Graphics.FillRectangle(brush, e.Bounds);
            if (e.Index >= 0)
            {
                TextRenderer.DrawText(e.Graphics, routerBox.Items[e.Index].ToString(), Font, e.Bounds, fore,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            }
        }

        // ---------- Settings ----------

        void ShowSettings()
        {
            if (settingsForm != null && !settingsForm.IsDisposed)
            {
                settingsForm.Activate();
                return;
            }
            settingsForm = new SettingsForm(settings, ApplySettings);
            settingsForm.FormClosed += delegate { settingsForm = null; };
            settingsForm.Show();
        }

        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HTCAPTION = 2;

        [DllImport("user32.dll")]
        static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    }
}
