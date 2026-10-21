using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace PingGadget
{
    // "Disconnect Internet" moves the router-facing adapter to 10.10.10.X/24 (X = the last number of
    // its address) with no gateway and no DNS; "Connect Internet" puts back what it had. The original
    // settings are written to a file before anything changes, so they can be restored even after the
    // app is restarted, crashes, or Windows reboots (the 10.10.10.X settings are persistent).
    static class Internet
    {
        const string OfflinePrefix = "10.10.10.";
        const string OfflineMask = "255.255.255.0";

        static readonly string StateFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PingGadget", "offline.ini");

        // True while the app has the internet disconnected (and the original settings saved).
        public static bool IsDisconnected
        {
            get { return File.Exists(StateFile); }
        }

        public static void Disconnect(IEnumerable<RouterInfo> routers)
        {
            if (IsDisconnected) throw new InvalidOperationException("The internet is already disconnected.");

            NetworkInterface nic = NetworkManager.FindAdapter(routers);
            if (nic == null)
                throw new InvalidOperationException("No connected network adapter is on the same subnet as the routers in Settings.");
            IPAddress local = NetworkManager.FindRouterSubnetAddress(nic, routers);
            int ifIndex = nic.GetIPProperties().GetIPv4Properties().Index;

            var state = new Dictionary<string, string>();
            bool found = NetworkManager.WithAdapterConfig("InterfaceIndex = " + ifIndex, delegate(ManagementObject mo)
            {
                if ((bool)mo["DHCPEnabled"])
                    throw new InvalidOperationException("The adapter uses DHCP. Configure a static IP address on it first.");

                // WMI lists IPv4 and IPv6 entries together; only IPv4 is changed and restored.
                var ips = new List<string>();
                var masks = new List<string>();
                string[] allIps = (string[])mo["IPAddress"] ?? new string[0];
                string[] allMasks = (string[])mo["IPSubnet"] ?? new string[0];
                for (int i = 0; i < allIps.Length && i < allMasks.Length; i++)
                {
                    if (!IsIPv4(allIps[i])) continue;
                    ips.Add(allIps[i]);
                    masks.Add(allMasks[i]);
                }

                var gateways = new List<string>();
                var metrics = new List<string>();
                string[] allGateways = (string[])mo["DefaultIPGateway"] ?? new string[0];
                ushort[] allMetrics = (ushort[])mo["GatewayCostMetric"] ?? new ushort[0];
                for (int i = 0; i < allGateways.Length; i++)
                {
                    if (!IsIPv4(allGateways[i])) continue;
                    gateways.Add(allGateways[i]);
                    metrics.Add(i < allMetrics.Length ? allMetrics[i].ToString() : "256");
                }

                state["Adapter"] = (string)mo["SettingID"];
                state["Name"] = nic.Name;
                state["IP"] = string.Join(",", ips);
                state["Mask"] = string.Join(",", masks);
                state["Gateway"] = string.Join(",", gateways);
                state["GatewayMetric"] = string.Join(",", metrics);
                state["Dns"] = string.Join(",", (string[])mo["DNSServerSearchOrder"] ?? new string[0]);
            });
            if (!found)
                throw new InvalidOperationException("Network adapter #" + ifIndex + " was not found in WMI.");
            if (state["IP"].Length == 0)
                throw new InvalidOperationException("The adapter has no static IPv4 address to restore later.");

            SaveState(state);
            try
            {
                // WMI can't remove a gateway, but netsh can (from the saved configuration too).
                string offlineIp = OfflinePrefix + local.GetAddressBytes()[3];
                Netsh("interface ipv4 set address name=" + ifIndex + " source=static address=" + offlineIp +
                    " mask=" + OfflineMask + " gateway=none");
            }
            catch
            {
                // Forget the saved settings only if the address really didn't change.
                Reconcile();
                throw;
            }
            // The internet is already cut off here; if clearing DNS fails, Connect still restores it.
            Netsh("interface ipv4 set dnsservers name=" + ifIndex + " source=static address=none validate=no");
        }

        public static void Connect()
        {
            if (!IsDisconnected) throw new InvalidOperationException("The internet isn't disconnected.");
            Dictionary<string, string> state = LoadState();
            string adapter = Guid.Parse(Get(state, "Adapter")).ToString("B");
            string[] ips = Split(Get(state, "IP"));
            string[] masks = Split(Get(state, "Mask"));
            string[] gateways = Split(Get(state, "Gateway"));
            string[] metricText = Split(Get(state, "GatewayMetric"));
            string[] dns = Split(Get(state, "Dns"));
            if (ips.Length == 0 || ips.Length != masks.Length || gateways.Length != metricText.Length)
                throw new InvalidOperationException("The saved network settings in " + StateFile + " are damaged.");
            var metrics = new ushort[metricText.Length];
            for (int i = 0; i < metrics.Length; i++) metrics[i] = ushort.Parse(metricText[i]);

            bool found = NetworkManager.WithAdapterConfig("SettingID = '" + adapter + "'", delegate(ManagementObject mo)
            {
                NetworkManager.InvokeConfig(mo, "EnableStatic", "restore the IP address",
                    "IPAddress", ips, "SubnetMask", masks);
                if (gateways.Length > 0)
                    NetworkManager.InvokeConfig(mo, "SetGateways", "restore the gateway",
                        "DefaultIPGateway", gateways, "GatewayCostMetric", metrics);
                NetworkManager.InvokeConfig(mo, "SetDNSServerSearchOrder", "restore the DNS servers",
                    "DNSServerSearchOrder", dns.Length > 0 ? dns : null);
            });
            if (!found)
            {
                string name;
                state.TryGetValue("Name", out name);
                throw new InvalidOperationException("The network adapter \"" + name + "\" was not found. Is it disabled or removed?");
            }
            File.Delete(StateFile);
        }

        // Forgets the saved settings when the adapter is up but no longer on 10.10.10.X, i.e. someone
        // changed its IP by hand; "Connect Internet" would otherwise overwrite their change. While the
        // adapter is down or missing (e.g. during boot) the saved settings are kept.
        public static void Reconcile()
        {
            if (!IsDisconnected) return;
            NetworkInterface nic = FindSavedAdapter();
            if (nic == null || nic.OperationalStatus != OperationalStatus.Up) return;

            bool hasIPv4 = false;
            foreach (UnicastIPAddressInformation a in nic.GetIPProperties().UnicastAddresses)
            {
                if (a.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (a.Address.ToString().StartsWith(OfflinePrefix)) return;
                hasIPv4 = true;
            }
            if (hasIPv4) File.Delete(StateFile);
        }

        // The adapter we disconnected (it's no longer on the routers' subnet, so FindAdapter misses it).
        public static NetworkInterface FindSavedAdapter()
        {
            string adapter = SavedValue("Adapter");
            if (adapter == null) return null;
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                if (string.Equals(nic.Id, adapter, StringComparison.OrdinalIgnoreCase)) return nic;
            return null;
        }

        // The gateway that Connect will restore, or null.
        public static IPAddress SavedGateway()
        {
            string[] gateways = Split(SavedValue("Gateway") ?? "");
            IPAddress ip;
            return gateways.Length > 0 && IPAddress.TryParse(gateways[0], out ip) ? ip : null;
        }

        static string SavedValue(string key)
        {
            string value;
            try
            {
                return IsDisconnected && LoadState().TryGetValue(key, out value) ? value : null;
            }
            catch (IOException)
            {
                return null;
            }
        }

        static void Netsh(string args)
        {
            var psi = new ProcessStartInfo("netsh.exe", args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0)
                    throw new InvalidOperationException("netsh " + args + " failed: " + output.Trim());
            }
        }

        static bool IsIPv4(string s)
        {
            IPAddress ip;
            return IPAddress.TryParse(s, out ip) && ip.AddressFamily == AddressFamily.InterNetwork;
        }

        static string[] Split(string list)
        {
            return list.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        }

        static string Get(Dictionary<string, string> state, string key)
        {
            string value;
            if (!state.TryGetValue(key, out value))
                throw new InvalidOperationException("The saved network settings in " + StateFile + " are damaged (no " + key + ").");
            return value;
        }

        static Dictionary<string, string> LoadState()
        {
            var state = new Dictionary<string, string>();
            foreach (string line in File.ReadAllLines(StateFile))
            {
                int eq = line.IndexOf('=');
                if (eq > 0) state[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
            return state;
        }

        static void SaveState(Dictionary<string, string> state)
        {
            var lines = new List<string>();
            foreach (KeyValuePair<string, string> kv in state) lines.Add(kv.Key + "=" + kv.Value);
            Directory.CreateDirectory(Path.GetDirectoryName(StateFile));
            File.WriteAllLines(StateFile, lines);
        }
    }
}
