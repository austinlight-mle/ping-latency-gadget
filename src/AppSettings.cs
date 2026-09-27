using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;

namespace PingGadget
{
    class RouterInfo
    {
        public string Name;
        public string Ip;

        public RouterInfo(string name, string ip)
        {
            Name = name;
            Ip = ip;
        }

        public override string ToString()
        {
            return Name;
        }
    }

    class AppSettings
    {
        public const string DefaultAstrillPath = @"C:\Program Files (x86)\Astrill\astrill.exe";

        public const int MinAutoSwitchSeconds = 3, MinSwitchTimeoutSeconds = 20, MaxSeconds = 600;

        public List<RouterInfo> Routers = new List<RouterInfo>();
        public string PingTarget = "teams.com";
        public bool ShowPing = true;
        public bool ShowUpload = true;
        public bool ShowDownload = true;
        public bool ToggleAstrill = true;
        public bool AutoSwitch = false;
        public int AutoSwitchSeconds = 10;
        public int SwitchTimeoutSeconds = 60;
        public string AstrillPath = DefaultAstrillPath;
        public Color ForeColor = Color.Lime;
        public Color BackColor = Color.Black;
        public float FontSize = 10f;
        public int Opacity = 85;
        public int X = int.MinValue;
        public int Y = int.MinValue;

        static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PingGadget", "settings.ini");

        public static AppSettings Load()
        {
            var s = new AppSettings();
            if (!File.Exists(FilePath))
            {
                s.Routers.Add(new RouterInfo("Router 1", "192.168.1.1"));
                s.Routers.Add(new RouterInfo("Router 2", "192.168.1.2"));
                s.Routers.Add(new RouterInfo("Router 3", "192.168.1.3"));
                return s;
            }

            foreach (string line in File.ReadAllLines(FilePath))
            {
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string key = line.Substring(0, eq).Trim();
                string val = line.Substring(eq + 1).Trim();
                try
                {
                    switch (key)
                    {
                        case "Router":
                            int bar = val.LastIndexOf('|');
                            if (bar > 0) s.Routers.Add(new RouterInfo(val.Substring(0, bar), val.Substring(bar + 1)));
                            break;
                        case "PingTarget": s.PingTarget = val; break;
                        case "ShowPing": s.ShowPing = val == "1"; break;
                        case "ShowUpload": s.ShowUpload = val == "1"; break;
                        case "ShowDownload": s.ShowDownload = val == "1"; break;
                        case "ToggleAstrill":
                        case "RestartAstrill": s.ToggleAstrill = val == "1"; break;
                        case "AstrillPath": s.AstrillPath = val; break;
                        case "AutoSwitch": s.AutoSwitch = val == "1"; break;
                        case "AutoSwitchSeconds": s.AutoSwitchSeconds = int.Parse(val, CultureInfo.InvariantCulture); break;
                        case "SwitchTimeoutSeconds": s.SwitchTimeoutSeconds = int.Parse(val, CultureInfo.InvariantCulture); break;
                        case "ForeColor": s.ForeColor = ColorTranslator.FromHtml(val); break;
                        case "BackColor": s.BackColor = ColorTranslator.FromHtml(val); break;
                        case "FontSize": s.FontSize = float.Parse(val, CultureInfo.InvariantCulture); break;
                        case "Opacity": s.Opacity = int.Parse(val, CultureInfo.InvariantCulture); break;
                        case "X": s.X = int.Parse(val, CultureInfo.InvariantCulture); break;
                        case "Y": s.Y = int.Parse(val, CultureInfo.InvariantCulture); break;
                    }
                }
                catch (Exception)
                {
                    // Ignore malformed values (bad number, out of range, unknown color) and keep the default.
                }
            }

            // Hand-edited values outside what the Settings window allows would misbehave (a zero font
            // size throws, a zero auto-switch delay switches every second), so clamp them the same way.
            s.AutoSwitchSeconds = Clamp(s.AutoSwitchSeconds, MinAutoSwitchSeconds, MaxSeconds);
            s.SwitchTimeoutSeconds = Clamp(s.SwitchTimeoutSeconds, MinSwitchTimeoutSeconds, MaxSeconds);
            s.Opacity = Clamp(s.Opacity, 20, 100);
            s.FontSize = float.IsNaN(s.FontSize) ? 10f : Math.Max(6f, Math.Min(36f, s.FontSize));
            return s;
        }

        public void Save()
        {
            var lines = new List<string>();
            foreach (RouterInfo r in Routers) lines.Add("Router=" + r.Name + "|" + r.Ip);
            lines.Add("PingTarget=" + PingTarget);
            lines.Add("ShowPing=" + (ShowPing ? "1" : "0"));
            lines.Add("ShowUpload=" + (ShowUpload ? "1" : "0"));
            lines.Add("ShowDownload=" + (ShowDownload ? "1" : "0"));
            lines.Add("ToggleAstrill=" + (ToggleAstrill ? "1" : "0"));
            lines.Add("AstrillPath=" + AstrillPath);
            lines.Add("AutoSwitch=" + (AutoSwitch ? "1" : "0"));
            lines.Add("AutoSwitchSeconds=" + AutoSwitchSeconds.ToString(CultureInfo.InvariantCulture));
            lines.Add("SwitchTimeoutSeconds=" + SwitchTimeoutSeconds.ToString(CultureInfo.InvariantCulture));
            lines.Add("ForeColor=" + ToHex(ForeColor));
            lines.Add("BackColor=" + ToHex(BackColor));
            lines.Add("FontSize=" + FontSize.ToString(CultureInfo.InvariantCulture));
            lines.Add("Opacity=" + Opacity.ToString(CultureInfo.InvariantCulture));
            lines.Add("X=" + X.ToString(CultureInfo.InvariantCulture));
            lines.Add("Y=" + Y.ToString(CultureInfo.InvariantCulture));

            Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            File.WriteAllLines(FilePath, lines);
        }

        public AppSettings Clone()
        {
            var c = (AppSettings)MemberwiseClone();
            c.Routers = new List<RouterInfo>();
            foreach (RouterInfo r in Routers) c.Routers.Add(new RouterInfo(r.Name, r.Ip));
            return c;
        }

        static int Clamp(int v, int min, int max)
        {
            return Math.Max(min, Math.Min(max, v));
        }

        static string ToHex(Color c)
        {
            return "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2");
        }
    }
}
