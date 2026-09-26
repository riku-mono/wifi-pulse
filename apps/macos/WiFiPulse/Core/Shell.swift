import Foundation

/// macOS 標準コマンドの実行。すべて読み取り専用のコマンドだけを呼ぶ。
nonisolated enum Shell {
    /// コマンドを実行し、標準出力を文字列で返す。失敗・タイムアウト時は途中までの出力（多くは空文字）。
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 15) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runSync(executable, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ executable: String, _ args: [String], timeout: TimeInterval = 15) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

/// いま使っている経路の情報（インターフェース・ルーター・自分のIP）。
nonisolated struct NetworkEnvironment: Equatable, Sendable {
    var interface: String = "en0"
    var gateway: String = ""
    var selfIP: String = ""
    var wifiDevice: String = "en0"
    /// ルーターの MAC アドレス。位置情報の許可が無くても取れるので、ネットワークの識別に使う。
    var routerMAC: String = ""

    /// 記録をネットワークごとに分けるための識別子。メッシュの中継機を移っても変わらない（ルーター単位）。
    var networkID: String? {
        if !routerMAC.isEmpty { return routerMAC }
        return gateway.isEmpty ? nil : "ip:\(gateway)"
    }

    static func resolve() async -> NetworkEnvironment {
        var env = NetworkEnvironment()
        let ports = await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        if let r = ports.firstMatch(of: #/Hardware Port: Wi-Fi\s*\nDevice:\s*(\S+)/#) {
            env.wifiDevice = String(r.1)
        }
        let route = await Shell.run("/sbin/route", ["-n", "get", "default"])
        if let r = route.firstMatch(of: #/interface:\s*(\S+)/#) { env.interface = String(r.1) }
        else { env.interface = env.wifiDevice }
        let dhcpRouter = await Shell.run("/usr/sbin/ipconfig", ["getoption", env.interface, "router"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dhcpRouter.wholeMatch(of: #/\d+\.\d+\.\d+\.\d+/#) != nil {
            env.gateway = dhcpRouter
        } else if let r = route.firstMatch(of: #/gateway:\s*(\d+\.\d+\.\d+\.\d+)/#) {
            env.gateway = String(r.1)
        }
        env.selfIP = await Shell.run("/usr/sbin/ipconfig", ["getifaddr", env.interface])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.gateway.isEmpty {
            env.routerMAC = await routerMAC(env.gateway)
        }
        return env
    }

    /// 接続直後は ARP 表にまだ載っていないことがあるので、無ければ1回 ping してから引き直す。
    static func routerMAC(_ gateway: String) async -> String {
        func lookup() async -> String? {
            let out = await Shell.run("/usr/sbin/arp", ["-n", gateway])
            return parseARP(out)
        }
        if let mac = await lookup() { return mac }
        _ = await Shell.run("/sbin/ping", ["-c", "1", "-t", "1", gateway], timeout: 2)
        return await lookup() ?? ""
    }

    /// `arp -n` の1行から MAC を取り出す（`? (192.168.1.1) at 0:1a:2b:3c:4d:5e on en0 ...`）。
    static func parseARP(_ out: String) -> String? {
        guard let m = out.firstMatch(of: #/\) at ([0-9a-fA-F:]{11,17})/#) else { return nil }
        return DeviceScanner.normalize(String(m.1))
    }
}

/// インターフェースの送受信バイト数（getifaddrs）。32bitカウンタなので差分は折り返しを考慮して取る。
nonisolated enum InterfaceCounters {
    struct Reading: Sendable {
        let rx: UInt32
        let tx: UInt32
        let at: Date
    }

    static func read(_ name: String) -> Reading? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: ifa.pointee.ifa_name) == name,
                  let raw = ifa.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return Reading(rx: data.ifi_ibytes, tx: data.ifi_obytes, at: Date())
        }
        return nil
    }
}
