import Foundation

// One ICMP echo through /sbin/ping (ICMP needs privileges that the system ping already has).
enum Pinger {
    struct Reply {
        let ok: Bool
        let text: String
    }

    // Calls back on the main queue.
    static func send(_ host: String, timeoutMs: Int, completion: @escaping (Reply) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let reply = run(host, timeoutMs: timeoutMs)
            DispatchQueue.main.async { completion(reply) }
        }
    }

    private static func run(_ host: String, timeoutMs: Int) -> Reply {
        if host.isEmpty || host.hasPrefix("-") { return Reply(ok: false, text: "Time=no host") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-n", "-c", "1", "-W", String(timeoutMs), "-t", String(timeoutMs / 1000 + 1), host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return Reply(ok: false, text: "Time=error")
        }
        // A hanging name lookup isn't covered by ping's own timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs + 3000)) {
            if p.isRunning { p.terminate() }
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        // 64 bytes from 52.112.0.1: icmp_seq=0 ttl=105 time=250.123 ms
        if p.terminationStatus == 0,
           let ms = value(after: "time=", in: output).flatMap(Double.init) {
            let ttl = value(after: "ttl=", in: output) ?? "-"
            return Reply(ok: true, text: "Time=\(Int(ms.rounded()))ms TTL=\(ttl)")
        }
        if p.terminationStatus == 68 || output.contains("cannot resolve") { return Reply(ok: false, text: "Time=no host") }
        if output.contains("Network is unreachable") { return Reply(ok: false, text: "Time=DestinationNetworkUnreachable") }
        if output.contains("Host Unreachable") || output.contains("No route to host") {
            return Reply(ok: false, text: "Time=DestinationHostUnreachable")
        }
        if p.terminationStatus == 2 || p.terminationReason == .uncaughtSignal { return Reply(ok: false, text: "Time=timeout") }
        return Reply(ok: false, text: "Time=error")
    }

    private static func value(after key: String, in text: String) -> String? {
        guard let r = text.range(of: key) else { return nil }
        let rest = text[r.upperBound...]
        let v = rest.prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }
}
