using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

namespace PingGadget
{
    static class NetworkManager
    {
        // A switch that timed out may still be running; never let two touch Astrill or routes at once.
        static readonly object SwitchLock = new object();

        // Finds the connected adapter whose IPv4 subnet contains the router address.
        public static NetworkInterface FindAdapter(IPAddress router)
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;

                foreach (UnicastIPAddressInformation a in nic.GetIPProperties().UnicastAddresses)
                {
                    if (a.Address.AddressFamily == AddressFamily.InterNetwork && a.IPv4Mask != null &&
                        SameSubnet(a.Address, router, a.IPv4Mask))
                        return nic;
                }
            }
            return null;
        }

        public static NetworkInterface FindAdapter(IEnumerable<RouterInfo> routers)
        {
            foreach (RouterInfo r in routers)
            {
                IPAddress ip;
                if (!IPAddress.TryParse(r.Ip, out ip)) continue;
                NetworkInterface nic = FindAdapter(ip);
                if (nic != null) return nic;
            }
            return null;
        }

        public static IPAddress GetGateway(NetworkInterface nic)
        {
            foreach (GatewayIPAddressInformation g in nic.GetIPProperties().GatewayAddresses)
            {
                if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any))
                    return g.Address;
            }
            return null;
        }

        // Turns Astrill off, points the adapter at the new gateway, then turns Astrill back on.
        // Returns false when the VPN hadn't reconnected by the time the switch was cancelled.
        public static bool SwitchRouter(IPAddress newGw, AppSettings settings, CancellationToken cancel)
        {
            while (!Monitor.TryEnter(SwitchLock, 250)) cancel.ThrowIfCancellationRequested();
            try
            {
                cancel.ThrowIfCancellationRequested();
                NetworkInterface nic = FindAdapter(newGw);
                if (nic == null)
                    throw new InvalidOperationException("No connected network adapter is on the same subnet as " + newGw + ".");

                int ifIndex = nic.GetIPProperties().GetIPv4Properties().Index;
                IPAddress oldGw = GetGateway(nic);

                AstrillOffResult astrill = settings.ToggleAstrill ? Astrill.TurnOff() : AstrillOffResult.Untouched;
                bool vpnBack = true;
                try
                {
                    // Too late: the user has been told it timed out, so don't change the gateway now.
                    cancel.ThrowIfCancellationRequested();
                    SetAdapterGateway(ifIndex, newGw);
                    if (oldGw != null && !oldGw.Equals(newGw))
                        MoveRoutes(ifIndex, oldGw, newGw);
                }
                finally
                {
                    // Bring the VPN back even if the gateway change failed or was cancelled.
                    vpnBack = Astrill.TurnOn(astrill, settings.AstrillPath, cancel);
                }
                return vpnBack;
            }
            finally
            {
                Monitor.Exit(SwitchLock);
            }
        }

        // True while a VPN has installed its 0.0.0.0/1 "override default" route.
        public static bool IsVpnRouted()
        {
            uint halfMask = ToUInt32(IPAddress.Parse("128.0.0.0"));
            foreach (MIB_IPFORWARDROW r in GetRoutes())
                if (r.dwForwardDest == 0 && r.dwForwardMask == halfMask) return true;
            return false;
        }

        static void SetAdapterGateway(int ifIndex, IPAddress gw)
        {
            string query = "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE InterfaceIndex = " + ifIndex;
            using (var searcher = new ManagementObjectSearcher(query))
            using (ManagementObjectCollection results = searcher.Get())
            {
                foreach (ManagementObject mo in results)
                {
                    using (mo)
                    {
                        if ((bool)mo["DHCPEnabled"])
                            throw new InvalidOperationException(
                                "The adapter uses DHCP. Configure a static IP address on it first.");

                        using (ManagementBaseObject inParams = mo.GetMethodParameters("SetGateways"))
                        {
                            inParams["DefaultIPGateway"] = new string[] { gw.ToString() };
                            inParams["GatewayCostMetric"] = new ushort[] { 256 };
                            using (ManagementBaseObject outParams = mo.InvokeMethod("SetGateways", inParams, null))
                            {
                                uint rc = Convert.ToUInt32(outParams["ReturnValue"]);
                                // 0 = success, 1 = success but reboot required.
                                if (rc != 0 && rc != 1)
                                    throw new InvalidOperationException(
                                        "Windows refused to change the gateway (WMI error " + rc + ").");
                            }
                        }
                        return;
                    }
                }
            }
            throw new InvalidOperationException("Network adapter #" + ifIndex + " was not found in WMI.");
        }

        // Re-points routes that still use the old gateway (e.g. the VPN server host route
        // Astrill adds) at the new gateway, and drops any stale default route.
        static void MoveRoutes(int ifIndex, IPAddress oldGw, IPAddress newGw)
        {
            uint oldHop = ToUInt32(oldGw);
            uint newHop = ToUInt32(newGw);

            foreach (MIB_IPFORWARDROW r in GetRoutes())
            {
                if (r.dwForwardIfIndex != ifIndex || r.dwForwardNextHop != oldHop) continue;

                MIB_IPFORWARDROW row = r;
                DeleteIpForwardEntry(ref row);
                if (row.dwForwardDest == 0 && row.dwForwardMask == 0) continue;

                row.dwForwardNextHop = newHop;
                row.dwForwardProto = MIB_IPPROTO_NETMGMT;
                int rc = CreateIpForwardEntry(ref row);
                if (rc != 0 && rc != ERROR_OBJECT_ALREADY_EXISTS)
                    throw new Win32Exception(rc, "Gateway switched, but moving the route to " +
                        new IPAddress(row.dwForwardDest) + " failed.");
            }
        }

        static List<MIB_IPFORWARDROW> GetRoutes()
        {
            var list = new List<MIB_IPFORWARDROW>();
            int size = 0;
            int rc = GetIpForwardTable(IntPtr.Zero, ref size, false);
            while (true)
            {
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    rc = GetIpForwardTable(buf, ref size, false);
                    if (rc == ERROR_INSUFFICIENT_BUFFER) continue;
                    if (rc != 0) throw new Win32Exception(rc);

                    int count = Marshal.ReadInt32(buf);
                    int rowSize = Marshal.SizeOf(typeof(MIB_IPFORWARDROW));
                    for (int i = 0; i < count; i++)
                    {
                        IntPtr p = IntPtr.Add(buf, 4 + i * rowSize);
                        list.Add((MIB_IPFORWARDROW)Marshal.PtrToStructure(p, typeof(MIB_IPFORWARDROW)));
                    }
                    return list;
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
        }

        static bool SameSubnet(IPAddress a, IPAddress b, IPAddress mask)
        {
            byte[] ab = a.GetAddressBytes(), bb = b.GetAddressBytes(), mb = mask.GetAddressBytes();
            if (ab.Length != 4 || bb.Length != 4 || mb.Length != 4) return false;
            for (int i = 0; i < 4; i++)
                if ((ab[i] & mb[i]) != (bb[i] & mb[i])) return false;
            return true;
        }

        static uint ToUInt32(IPAddress ip)
        {
            return BitConverter.ToUInt32(ip.GetAddressBytes(), 0);
        }

        const int ERROR_INSUFFICIENT_BUFFER = 122;
        const int ERROR_OBJECT_ALREADY_EXISTS = 5010;
        const uint MIB_IPPROTO_NETMGMT = 3;

        [StructLayout(LayoutKind.Sequential)]
        struct MIB_IPFORWARDROW
        {
            public uint dwForwardDest;
            public uint dwForwardMask;
            public uint dwForwardPolicy;
            public uint dwForwardNextHop;
            public int dwForwardIfIndex;
            public uint dwForwardType;
            public uint dwForwardProto;
            public uint dwForwardAge;
            public uint dwForwardNextHopAS;
            public uint dwForwardMetric1;
            public uint dwForwardMetric2;
            public uint dwForwardMetric3;
            public uint dwForwardMetric4;
            public uint dwForwardMetric5;
        }

        [DllImport("iphlpapi.dll")]
        static extern int GetIpForwardTable(IntPtr pIpForwardTable, ref int pdwSize, bool bOrder);

        [DllImport("iphlpapi.dll")]
        static extern int CreateIpForwardEntry(ref MIB_IPFORWARDROW pRoute);

        [DllImport("iphlpapi.dll")]
        static extern int DeleteIpForwardEntry(ref MIB_IPFORWARDROW pRoute);
    }
}
