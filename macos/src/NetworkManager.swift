import Foundation
import SystemConfiguration

// An IPv4 address as a host-order number (192.168.1.1 = 0xC0A80101).
struct IPv4: Equatable, CustomStringConvertible {
    let value: UInt32

    init(_ value: UInt32) { self.value = value }

    init?(_ text: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        value = UInt32(bigEndian: addr.s_addr)
    }

    var description: String {
        return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

struct Adapter {
    let name: String     // BSD name, e.g. en0
    let index: Int
}

struct Route {
    let dest: IPv4
    let mask: IPv4
    let gateway: IPv4?   // nil for link-layer (directly connected) routes
    let ifIndex: Int
    let flags: Int32
}

struct SwitchCancelled: Error {}

// The user cancelled the switch from the gadget's menu.
struct SwitchStopped: Error {}

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { return message }
}

// A cancellation flag that can also be waited on, like CancellationToken.WaitHandle.
final class CancelToken {
    private let cond = NSCondition()
    private var cancelled = false

    static let none = CancelToken()

    var isCancelled: Bool {
        cond.lock(); defer { cond.unlock() }
        return cancelled
    }

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    func cancel(afterMs ms: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.cancel() }
    }

    // Waits up to ms; returns true if cancelled.
    func wait(ms: Int) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(ms) / 1000)
        cond.lock(); defer { cond.unlock() }
        while !cancelled && cond.wait(until: deadline) {}
        return cancelled
    }

    func throwIfCancelled() throws {
        if isCancelled { throw SwitchCancelled() }
    }
}

enum NetworkManager {
    // A switch that timed out may still be running; never let two touch Astrill or routes at once.
    private static let switchLock = NSLock()

    // Finds the connected adapter whose IPv4 subnet contains the router address.
    static func findAdapter(_ router: IPv4) -> Adapter? {
        var result: Adapter?
        forEachInterface { ifa in
            let flags = Int32(ifa.ifa_flags)
            guard result == nil, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = ifa.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { return } // skip VPN tunnels
            let ip = ipv4(addr), mask = ipv4(maskPtr)
            if ip.value & mask.value == router.value & mask.value {
                let name = String(cString: ifa.ifa_name)
                result = Adapter(name: name, index: Int(if_nametoindex(name)))
            }
        }
        return result
    }

    static func findAdapter(_ routers: [RouterInfo]) -> Adapter? {
        for r in routers {
            if let ip = IPv4(r.ip), let nic = findAdapter(ip) { return nic }
        }
        return nil
    }

    // The adapter's default gateway, from the routing table.
    static func gateway(of nic: Adapter) -> IPv4? {
        var scoped: IPv4?
        for r in routes() where r.ifIndex == nic.index && r.dest.value == 0 && r.mask.value == 0 && r.flags & RTF_GATEWAY != 0 {
            guard let gw = r.gateway, gw.value != 0 else { continue }
            if r.flags & RTF_IFSCOPE == 0 { return gw }
            scoped = gw
        }
        return scoped
    }

    // Bytes sent and received on the adapter. The counters are 32-bit and wrap around,
    // so callers subtract with &- to get the traffic since the previous sample.
    static func byteCounters(_ nic: Adapter) -> (sent: UInt32, received: UInt32)? {
        var result: (UInt32, UInt32)?
        forEachInterface { ifa in
            guard result == nil, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data, String(cString: ifa.ifa_name) == nic.name else { return }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result = (stats.ifi_obytes, stats.ifi_ibytes)
        }
        return result
    }

    // Turns Astrill off, points the network service at the new gateway, then turns Astrill back on.
    // Returns how turning the VPN back on ended.
    static func switchRouter(_ newGw: IPv4, settings: AppSettings, cancel: CancelToken) throws -> VpnResult {
        while !switchLock.lock(before: Date(timeIntervalSinceNow: 0.25)) { try cancel.throwIfCancelled() }
        defer { switchLock.unlock() }

        try cancel.throwIfCancelled()
        guard let nic = findAdapter(newGw) else {
            throw SwitchError("No connected network adapter is on the same subnet as \(newGw).")
        }
        let oldGw = gateway(of: nic)
        // Checked before Astrill is touched, so a misconfigured adapter doesn't cost a VPN reconnect.
        let service = try NetworkService.find(bsdName: nic.name)
        try Helper.checkInstalled()

        let astrill = settings.toggleAstrill ? Astrill.turnOff() : .untouched
        var failure: Error?
        do {
            // Too late: the user has been told it timed out, so don't change the gateway now.
            try cancel.throwIfCancelled()
            try setServiceGateway(service, nic: nic, gateway: newGw)
            if let oldGw = oldGw, oldGw != newGw {
                try moveRoutes(nic, from: oldGw, to: newGw)
            }
        } catch {
            failure = error
        }
        // Bring the VPN back even if the gateway change failed or was cancelled.
        let vpn = try Astrill.turnOn(astrill, path: settings.astrillPath, cancel: cancel)
        if let failure = failure { throw failure }
        return vpn
    }

    // True while a VPN has installed its 0.0.0.0/1 "override default" route.
    static func isVpnRouted() -> Bool {
        let halfMask: UInt32 = 0x8000_0000
        return routes().contains { $0.dest.value == 0 && $0.mask.value == halfMask }
    }

    // macOS keeps the gateway in the network service's "Router" setting (Network settings →
    // Details → TCP/IP). Changing it there makes macOS replace the default route itself.
    private static func setServiceGateway(_ service: NetworkService, nic: Adapter, gateway: IPv4) throws {
        try Helper.run(["set-gateway", service.name, service.address, service.subnetMask, gateway.description])

        // networksetup returns before the system applies the change; wait for the new default route.
        let deadline = Date(timeIntervalSinceNow: 10)
        while self.gateway(of: nic) != gateway && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // Re-points routes that still use the old gateway (e.g. the VPN server host route
    // Astrill adds) at the new gateway, and drops any stale default route.
    private static func moveRoutes(_ nic: Adapter, from oldGw: IPv4, to newGw: IPv4) throws {
        for r in routes() {
            guard r.ifIndex == nic.index, r.gateway == oldGw, r.flags & RTF_GATEWAY != 0,
                  r.flags & RTF_WASCLONED == 0 else { continue }
            let scope = r.flags & RTF_IFSCOPE != 0 ? nic.name : "-"
            do {
                try Helper.run(["move-route", r.dest.description, r.mask.description, oldGw.description, newGw.description, scope])
            } catch {
                throw SwitchError("Gateway switched, but moving the route to \(r.dest) failed. \(error.localizedDescription)")
            }
        }
    }

    static func routes() -> [Route] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var buf = [UInt8]()
        var len = 0
        // The table can grow between the size query and the read; retry with the new size.
        for _ in 0..<5 {
            guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return [] }
            len += len / 8 + 512
            buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 { break }
            if errno != ENOMEM { return [] }
            len = 0
        }
        guard len > 0 else { return [] }

        var list = [Route]()
        buf.withUnsafeBytes { raw in
            let headerSize = MemoryLayout<rt_msghdr>.size
            var off = 0
            while off + headerSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
                let msgLen = Int(hdr.rtm_msglen)
                guard msgLen > 0, off + msgLen <= len else { break }

                // The header is followed by one socket address per bit set in rtm_addrs.
                var p = off + headerSize
                var addrs = [Int: (family: UInt8, bytes: [UInt8])]()
                for i in 0..<Int(RTAX_MAX) where hdr.rtm_addrs & (1 << i) != 0 && p < off + msgLen {
                    let saLen = Int(raw[p])
                    let family = saLen > 1 ? raw[p + 1] : 0
                    // A netmask may be cut short after its last non-zero byte.
                    let bytes = (0..<4).map { k in 4 + k < saLen ? raw[p + 4 + k] : 0 }
                    addrs[i] = (family, bytes)
                    p += saLen > 0 ? 1 + ((saLen - 1) | 3) : 4
                }

                if let dst = addrs[Int(RTAX_DST)], dst.family == UInt8(AF_INET) {
                    let mask: IPv4
                    if let m = addrs[Int(RTAX_NETMASK)] { mask = IPv4(bytes: m.bytes) }
                    else { mask = IPv4(hdr.rtm_flags & RTF_HOST != 0 ? 0xFFFF_FFFF : 0) }
                    var gw: IPv4?
                    if let g = addrs[Int(RTAX_GATEWAY)], g.family == UInt8(AF_INET) { gw = IPv4(bytes: g.bytes) }
                    list.append(Route(dest: IPv4(bytes: dst.bytes), mask: mask, gateway: gw,
                                      ifIndex: Int(hdr.rtm_index), flags: hdr.rtm_flags))
                }
                off += msgLen
            }
        }
        return list
    }

    private static func forEachInterface(_ body: (ifaddrs) -> Void) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            body(ifa.pointee)
            p = ifa.pointee.ifa_next
        }
    }

    private static func ipv4(_ sa: UnsafeMutablePointer<sockaddr>) -> IPv4 {
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
    }
}

private extension IPv4 {
    init(bytes b: [UInt8]) {
        self.init(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }
}

// The network service (Network settings entry) that owns an interface, and its IPv4 setup.
struct NetworkService {
    let name: String
    let address: String
    let subnetMask: String

    static func find(bsdName: String) throws -> NetworkService {
        guard let prefs = SCPreferencesCreate(nil, "PingGadget" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw SwitchError("Could not read the network settings.")
        }
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let iface = SCNetworkServiceGetInterface(service),
                  SCNetworkInterfaceGetBSDName(iface) as String? == bsdName else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? bsdName

            let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4)
            let config = proto.flatMap { SCNetworkProtocolGetConfiguration($0) } as? [String: Any] ?? [:]
            let method = config[kSCPropNetIPv4ConfigMethod as String] as? String
            guard method == (kSCValNetIPv4ConfigMethodManual as String),
                  let address = (config[kSCPropNetIPv4Addresses as String] as? [String])?.first,
                  let mask = (config[kSCPropNetIPv4SubnetMasks as String] as? [String])?.first else {
                throw SwitchError("\"\(name)\" gets its address from DHCP. Set Configure IPv4 to Manually " +
                                  "(System Settings → Network → \(name) → Details → TCP/IP) first.")
            }
            return NetworkService(name: name, address: address, subnetMask: mask)
        }
        throw SwitchError("No network service uses the adapter \(bsdName).")
    }
}

// Calls back on the main queue when an IPv4 address or router changes.
final class NetworkWatcher {
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "PingGadget" as CFString, { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &ctx)
        guard let store = store else { return }
        let patterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Service/.*/IPv4", "State:/Network/Global/IPv4"]
        SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
    }

    deinit {
        if let store = store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}
