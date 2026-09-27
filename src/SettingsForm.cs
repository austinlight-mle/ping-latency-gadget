using System;
using System.Drawing;
using System.Net;
using System.Net.Sockets;
using System.Windows.Forms;

namespace PingGadget
{
    class SettingsForm : Form
    {
        readonly AppSettings original;
        readonly Action<AppSettings> onSave;
        readonly bool startupWasEnabled;

        readonly FlowLayoutPanel routerRows;
        readonly TextBox pingBox;
        readonly CheckBox chkPing, chkUp, chkDown, chkStartup, chkAstrill, chkAutoSwitch;
        readonly Button foreColorBtn, backColorBtn;
        readonly NumericUpDown fontSizeBox, opacityBox, autoSwitchBox, switchTimeoutBox;

        public SettingsForm(AppSettings settings, Action<AppSettings> onSave)
        {
            original = settings;
            this.onSave = onSave;

            Text = "Ping Gadget Settings";
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            AutoScaleMode = AutoScaleMode.None;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Font = SystemFonts.MessageBoxFont;
            Padding = new Padding(S(10));

            var root = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            Controls.Add(root);

            // Routers
            root.Controls.Add(Header("Routers"));
            var captions = Flow();
            captions.Controls.Add(Caption("Name", S(140)));
            captions.Controls.Add(Caption("IP address", S(120)));
            root.Controls.Add(captions);

            routerRows = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Margin = Padding.Empty
            };
            root.Controls.Add(routerRows);
            foreach (RouterInfo r in settings.Routers) AddRouterRow(r.Name, r.Ip, -1);
            if (settings.Routers.Count == 0) AddRouterRow("", "", -1);

            // Ping target
            root.Controls.Add(Header("Ping"));
            pingBox = new TextBox { Text = settings.PingTarget, Width = S(270) };
            root.Controls.Add(pingBox);

            var autoRow = Flow();
            chkAutoSwitch = Check("Switch to next router when ping times out for", settings.AutoSwitch);
            chkAutoSwitch.Anchor = AnchorStyles.Left;
            autoSwitchBox = new NumericUpDown { Minimum = AppSettings.MinAutoSwitchSeconds, Maximum = AppSettings.MaxSeconds, Width = S(60) };
            autoSwitchBox.Value = settings.AutoSwitchSeconds;
            autoSwitchBox.Enabled = chkAutoSwitch.Checked;
            chkAutoSwitch.CheckedChanged += delegate { autoSwitchBox.Enabled = chkAutoSwitch.Checked; };
            autoRow.Controls.AddRange(new Control[] { chkAutoSwitch, autoSwitchBox, TextLabel("seconds") });
            root.Controls.Add(autoRow);

            // What to show
            root.Controls.Add(Header("Show"));
            var shows = Flow();
            chkPing = Check("Ping", settings.ShowPing);
            chkUp = Check("Upload", settings.ShowUpload);
            chkDown = Check("Download", settings.ShowDownload);
            shows.Controls.AddRange(new Control[] { chkPing, chkUp, chkDown });
            root.Controls.Add(shows);

            // Startup and VPN
            root.Controls.Add(Header("General"));
            startupWasEnabled = Startup.IsEnabled();
            chkStartup = Check("Run at Windows start", startupWasEnabled);
            chkAstrill = Check("Toggle Astrill VPN off/on when switching router", settings.ToggleAstrill);
            root.Controls.Add(chkStartup);
            root.Controls.Add(chkAstrill);

            var timeoutRow = Flow();
            switchTimeoutBox = new NumericUpDown { Minimum = AppSettings.MinSwitchTimeoutSeconds, Maximum = AppSettings.MaxSeconds, Width = S(60) };
            switchTimeoutBox.Value = settings.SwitchTimeoutSeconds;
            timeoutRow.Controls.AddRange(new Control[] { TextLabel("Stop waiting for a router switch after"), switchTimeoutBox, TextLabel("seconds") });
            root.Controls.Add(timeoutRow);

            // Style
            root.Controls.Add(Header("Style"));
            var style = new TableLayoutPanel { ColumnCount = 4, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            foreColorBtn = ColorButton(settings.ForeColor);
            backColorBtn = ColorButton(settings.BackColor);
            fontSizeBox = new NumericUpDown { Minimum = 6, Maximum = 36, DecimalPlaces = 0, Width = S(60) };
            fontSizeBox.Value = (decimal)Math.Max(6f, Math.Min(36f, settings.FontSize));
            opacityBox = new NumericUpDown { Minimum = 20, Maximum = 100, Increment = 5, Width = S(60) };
            opacityBox.Value = Math.Max(20, Math.Min(100, settings.Opacity));
            style.Controls.Add(TextLabel("Font color"), 0, 0);
            style.Controls.Add(foreColorBtn, 1, 0);
            style.Controls.Add(TextLabel("Background"), 2, 0);
            style.Controls.Add(backColorBtn, 3, 0);
            style.Controls.Add(TextLabel("Font size"), 0, 1);
            style.Controls.Add(fontSizeBox, 1, 1);
            style.Controls.Add(TextLabel("Opacity %"), 2, 1);
            style.Controls.Add(opacityBox, 3, 1);
            root.Controls.Add(style);

            // Save / Close
            var buttons = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.RightToLeft,
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Anchor = AnchorStyles.Right,
                Margin = new Padding(0, S(12), 0, 0)
            };
            var closeBtn = new Button { Text = "Close", AutoSize = true };
            var saveBtn = new Button { Text = "Save", AutoSize = true };
            closeBtn.Click += delegate { Close(); };
            saveBtn.Click += delegate { Save(); };
            buttons.Controls.Add(closeBtn);
            buttons.Controls.Add(saveBtn);
            root.Controls.Add(buttons);

            CancelButton = closeBtn;
        }

        void AddRouterRow(string name, string ip, int index)
        {
            var row = Flow();
            var nameBox = new TextBox { Text = name, Width = S(140) };
            var ipBox = new TextBox { Text = ip, Width = S(120) };
            var plus = new Button { Text = "+", Width = S(28), Height = ipBox.Height };
            var minus = new Button { Text = "-", Width = S(28), Height = ipBox.Height };

            plus.Click += delegate
            {
                AddRouterRow("", "", routerRows.Controls.GetChildIndex(row) + 1);
            };
            minus.Click += delegate
            {
                if (routerRows.Controls.Count > 1)
                {
                    routerRows.Controls.Remove(row);
                    row.Dispose();
                }
                else
                {
                    nameBox.Text = "";
                    ipBox.Text = "";
                }
            };

            row.Controls.AddRange(new Control[] { nameBox, ipBox, plus, minus });
            routerRows.Controls.Add(row);
            if (index >= 0)
            {
                routerRows.Controls.SetChildIndex(row, index);
                nameBox.Focus();
            }
        }

        void Save()
        {
            AppSettings s = original.Clone();

            s.Routers.Clear();
            foreach (Control row in routerRows.Controls)
            {
                TextBox nameBox = (TextBox)row.Controls[0];
                TextBox ipBox = (TextBox)row.Controls[1];
                string name = nameBox.Text.Trim();
                string ip = ipBox.Text.Trim();
                if (name.Length == 0 && ip.Length == 0) continue;

                IPAddress addr;
                if (!IPAddress.TryParse(ip, out addr) || addr.AddressFamily != AddressFamily.InterNetwork)
                {
                    Warn("\"" + ip + "\" is not a valid IPv4 address.");
                    ipBox.Focus();
                    return;
                }
                s.Routers.Add(new RouterInfo(name.Length > 0 ? name.Replace("|", "/") : ip, addr.ToString()));
            }

            s.PingTarget = pingBox.Text.Trim();
            if (s.PingTarget.Length == 0)
            {
                Warn("Enter a ping destination, e.g. teams.com.");
                pingBox.Focus();
                return;
            }

            s.ShowPing = chkPing.Checked;
            s.ShowUpload = chkUp.Checked;
            s.ShowDownload = chkDown.Checked;
            s.ToggleAstrill = chkAstrill.Checked;
            s.AutoSwitch = chkAutoSwitch.Checked;
            s.AutoSwitchSeconds = (int)autoSwitchBox.Value;
            s.SwitchTimeoutSeconds = (int)switchTimeoutBox.Value;
            s.ForeColor = foreColorBtn.BackColor;
            s.BackColor = backColorBtn.BackColor;
            s.FontSize = (float)fontSizeBox.Value;
            s.Opacity = (int)opacityBox.Value;

            try
            {
                onSave(s);
                if (chkStartup.Checked != startupWasEnabled) Startup.SetEnabled(chkStartup.Checked);
            }
            catch (Exception ex)
            {
                Warn("Could not save settings: " + ex.Message);
                return;
            }
            Close();
        }

        void Warn(string message)
        {
            MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        Button ColorButton(Color color)
        {
            var b = new Button { BackColor = color, Width = S(60), FlatStyle = FlatStyle.Flat };
            b.Click += delegate
            {
                using (var dlg = new ColorDialog { Color = b.BackColor, FullOpen = true })
                {
                    if (dlg.ShowDialog(this) == DialogResult.OK) b.BackColor = dlg.Color;
                }
            };
            return b;
        }

        Label Header(string text)
        {
            return new Label
            {
                Text = text,
                AutoSize = true,
                Font = new Font(Font, FontStyle.Bold),
                Margin = new Padding(0, S(10), 0, S(3))
            };
        }

        Label Caption(string text, int width)
        {
            return new Label { Text = text, AutoSize = false, Width = width, Height = Font.Height + S(2) };
        }

        Label TextLabel(string text)
        {
            return new Label { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, S(3), S(6), S(3)) };
        }

        static CheckBox Check(string text, bool value)
        {
            return new CheckBox { Text = text, Checked = value, AutoSize = true };
        }

        static FlowLayoutPanel Flow()
        {
            return new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Margin = Padding.Empty
            };
        }

        int S(int px)
        {
            return (int)Math.Round(px * DeviceDpi / 96.0);
        }
    }
}
