import AppKit
import Darwin
import Foundation
import Observation

/// 1本の接続（nettop の接続行）。
nonisolated struct NetConnection: Identifiable, Hashable, Sendable {
    let id: String
    let proto: String       // TCP / UDP
    let family: String      // IPv4 / IPv6
    let localHost: String
    let localPort: String
    let remoteHost: String
    let remotePort: String
    var interface: String = ""
    var state: String = ""
    var rxRate: Double = 0  // bytes/s
    var txRate: Double = 0
    var rxTotal: Int64 = 0  // 監視を始めてからの累計
    var txTotal: Int64 = 0
    var retransmitTotal: Int64 = 0
    var rttMs: Double?

    var isListening: Bool { remoteHost == "*" }
    var remoteScope: RemoteScope { RemoteScope(remoteHost) }
}

nonisolated enum RemoteScope: Sendable {
    case none, loopback, lan, internet

    init(_ host: String) {
        let h = host.lowercased()
        if h == "*" || h.isEmpty { self = .none }
        else if h.hasPrefix("127.") || h == "::1" { self = .loopback }
        else if h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") || h.hasPrefix("fe80:")
                    || h.hasPrefix("fd") || h.hasPrefix("fc") || h.hasPrefix("224.") || h.hasPrefix("239.") || h.hasPrefix("ff0") {
            self = .lan
        } else if h.hasPrefix("172."), let second = Int(h.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) {
            self = .lan
        } else { self = .internet }
    }

    var label: String {
        switch self {
        case .none: "—"
        case .loopback: String(localized: "このMac")
        case .lan: "LAN"
        case .internet: String(localized: "インターネット")
        }
    }
}

/// 1プロセスぶん（nettop のプロセス行＋その接続）。
nonisolated struct NetProcess: Identifiable, Hashable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    var rxRate: Double = 0
    var txRate: Double = 0
    var rxTotal: Int64 = 0
    var txTotal: Int64 = 0
    var retransmitTotal: Int64 = 0
    var connections: [NetConnection] = []
}

nonisolated struct ProcessSample: Sendable {
    let date: Date
    let processes: [NetProcess]
}

/// 画面に出す1行。「アプリごとにまとめる」ときは、ヘルパープロセスも親アプリに合算する。
nonisolated struct TrafficRow: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var bundlePath: String?
    var pids: [Int32]
    var rxRate: Double = 0
    var txRate: Double = 0
    var rxTotal: Int64 = 0
    var txTotal: Int64 = 0
    var retransmitTotal: Int64 = 0
    var connectionCount = 0
    var established = 0
    var rtt: Double?
    /// 並べ替え用のならした通信量（指数移動平均）。瞬間値で並べると2秒ごとに順位が入れ替わってしまう
    var smoothedRate: Double = 0
    /// 最後に通信があった時刻（「通信中のみ」でもしばらくは表示し続けるため）
    var lastActive: Date?

    var totalRate: Double { rxRate + txRate }
    var total: Int64 { rxTotal + txTotal }
    var rttSort: Double { rtt ?? -1 }
    var isActive: Bool { totalRate > 0 }
}

/// `nettop` を流しっぱなしにして、プロセス・接続ごとの通信量・RTT・再送を集める。
/// 負荷を抑えるため、「アプリの通信」画面を開いている間だけ動かす。
@Observable
final class ProcessMonitor {
    nonisolated static let interval = 2
    static let historyLength = 150 // 5分
    /// 通信が止まってもこの秒数は「通信中のみ」の一覧に残す
    static let lingerSeconds: TimeInterval = 30

    private(set) var isRunning = false
    private(set) var lastUpdate: Date?
    private(set) var processes: [NetProcess] = []
    private(set) var rows: [TrafficRow] = []
    private(set) var totalRx: Double = 0
    private(set) var totalTx: Double = 0
    private(set) var connectionCount = 0
    private(set) var failure: String?
    /// 行ID → 直近5分の（受信+送信）bytes/s
    private(set) var history: [(date: Date, rates: [String: Double])] = []

    var groupByApp = true {
        didSet {
            guard oldValue != groupByApp else { return }
            smoothed.removeAll(); lastActive.removeAll(); history.removeAll()
            rebuildRows(at: lastUpdate ?? Date())
        }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var parser: NettopParser?
    /// 見張り役の sh の標準入力。アプリが終了（強制終了・クラッシュを含む）すると自動で閉じ、
    /// それを合図に sh が nettop を止める。
    @ObservationIgnored private var stdinPipe: Pipe?
    /// start のたびに増やす。止めた nettop から遅れて届いたサンプルを捨てるため
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var smoothed: [String: Double] = [:]
    @ObservationIgnored private var lastActive: [String: Date] = [:]
    @ObservationIgnored private var appInfo: [Int32: AppInfo] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    struct AppInfo {
        let name: String
        let bundlePath: String?
    }

    func start() {
        guard process == nil else { return }
        generation += 1
        let gen = generation
        processes = []; rows = []; history = []; smoothed = [:]; lastActive = [:]
        totalRx = 0; totalTx = 0; connectionCount = 0; lastUpdate = nil; failure = nil

        // パイプだと nettop は16KBずつまとめて書き出す（数秒遅れ・サンプルが行の途中で切れる）。
        // 疑似端末につなぐと1行ずつ即座に出力されるので、そちらで受ける。
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            failure = String(localized: "疑似端末を開けませんでした")
            return
        }
        var attrs = termios()
        tcgetattr(slave, &attrs)
        cfmakeraw(&attrs) // 改行の変換（\n → \r\n）などを止める
        tcsetattr(slave, TCSANOW, &attrs)

        let parser = NettopParser(interval: Double(Self.interval)) { [weak self] sample in
            Task { @MainActor in self?.receive(sample, generation: gen) }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.watchdog, "sh",
                       "-L", "0", "-s", String(Self.interval), "-d", "-n", "-x",
                       "-J", "interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg"]
        p.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        p.standardInput = stdin
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.terminated(status: status, generation: gen) }
        }
        do {
            try p.run()
        } catch {
            close(master); close(slave)
            failure = String(localized: "nettop を起動できませんでした")
            return
        }
        close(slave) // 子プロセス側だけが持つ
        parser.attach(fd: master)
        self.parser = parser
        stdinPipe = stdin
        process = p
        isRunning = true
    }

    /// nettop を見張る sh スクリプト。
    /// - nettop は標準入力が EOF になると空回りして CPU を100%以上使うので、終わらない `sleep` をつないでおく
    /// - アプリが終わると sh の標準入力が EOF になるので、`read` を抜けて nettop と sleep を止める
    ///   （macOS には親の終了で子を止める仕組みが無く、これが無いと nettop が取り残されて空回りし続ける）
    static let watchdog = """
        sleep 2147483647 | /usr/bin/nettop "$@" &
        NETTOP=$!
        cleanup() { kill "$NETTOP" 2>/dev/null; pkill -P $$ 2>/dev/null; exit 0; }
        trap cleanup TERM INT HUP
        read -r _
        cleanup
        """

    func stop() {
        generation += 1
        process?.terminationHandler = nil
        // SIGTERM でも trap で片付くが、標準入力を閉じるのが正規の止め方
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        parser?.detach()
        parser = nil
        stdinPipe = nil
        isRunning = false
    }

    private func terminated(status: Int32, generation gen: Int) {
        guard gen == generation, isRunning else { return }
        // 画面を開いたまま nettop が落ちた場合は、少し待って張り直す
        process = nil
        parser?.detach()
        parser = nil
        isRunning = false
        failure = String(localized: "nettop が終了しました（\(status)）。再起動します…")
        Task {
            try? await Task.sleep(for: .seconds(2))
            if gen == generation, !isRunning { start() }
        }
    }

    private func receive(_ s: ProcessSample, generation gen: Int) {
        guard gen == generation, isRunning else { return }
        let isUpdateOfSameSample = lastUpdate == s.date
        processes = s.processes
        lastUpdate = s.date
        failure = nil
        totalRx = s.processes.reduce(0) { $0 + $1.rxRate }
        totalTx = s.processes.reduce(0) { $0 + $1.txRate }
        connectionCount = s.processes.reduce(0) { $0 + $1.connections.filter { !$0.isListening }.count }
        rebuildRows(at: s.date, advanceSmoothing: !isUpdateOfSameSample)
        var rates: [String: Double] = [:]
        for r in rows where r.totalRate > 0 { rates[r.id] = r.totalRate }
        if isUpdateOfSameSample, !history.isEmpty {
            history[history.count - 1] = (s.date, rates)
        } else {
            history.append((s.date, rates))
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
    }

    private func rebuildRows(at date: Date, advanceSmoothing: Bool = false) {
        var map: [String: TrafficRow] = [:]
        var rtts: [String: [Double]] = [:]
        for p in processes {
            let info = self.info(for: p)
            let key = groupByApp ? (info.bundlePath ?? "name:\(p.name)") : "pid:\(p.pid)"
            var row = map[key] ?? TrafficRow(id: key, name: groupByApp ? info.name : p.name, bundlePath: info.bundlePath, pids: [])
            row.pids.append(p.pid)
            row.rxRate += p.rxRate
            row.txRate += p.txRate
            row.rxTotal += p.rxTotal
            row.txTotal += p.txTotal
            row.retransmitTotal += p.retransmitTotal
            let conns = p.connections.filter { !$0.isListening }
            row.connectionCount += conns.count
            row.established += conns.filter { $0.state == "Established" }.count
            rtts[key, default: []] += conns.compactMap(\.rttMs)
            map[key] = row
        }
        for (key, var row) in map {
            row.pids.sort()
            row.rtt = median(rtts[key] ?? [])
            let prev = smoothed[key] ?? row.totalRate
            let ema = advanceSmoothing ? prev * 0.6 + row.totalRate * 0.4 : prev
            smoothed[key] = ema
            row.smoothedRate = ema
            if row.isActive { lastActive[key] = date }
            row.lastActive = lastActive[key]
            map[key] = row
        }
        let new = map.values.sorted { $0.id < $1.id }
        if new != rows { rows = new }
    }

    /// 「通信中のみ」のときに表示するか
    func isRecentlyActive(_ row: TrafficRow, now: Date) -> Bool {
        row.isActive || (row.lastActive.map { now.timeIntervalSince($0) < Self.lingerSeconds } ?? false)
    }

    func connections(for row: TrafficRow) -> [NetConnection] {
        processes.filter { row.pids.contains($0.pid) }.flatMap(\.connections)
    }

    // MARK: App identity

    private func info(for p: NetProcess) -> AppInfo {
        if let cached = appInfo[p.pid] { return cached }
        let path = Self.executablePath(p.pid)
        var bundle: String?
        if let path, let r = path.range(of: ".app/", options: .caseInsensitive) {
            bundle = String(path[..<r.upperBound].dropLast())
        }
        let name = bundle.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") } ?? p.name
        let info = AppInfo(name: name, bundlePath: bundle)
        appInfo[p.pid] = info
        if appInfo.count > 4000 { appInfo.removeAll() } // PID の使い回し対策も兼ねてたまに捨てる
        return info
    }

    func icon(for row: TrafficRow) -> NSImage? {
        guard let path = row.bundlePath else { return nil }
        if let i = iconCache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = i
        return i
    }

    nonisolated static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// nettop の CSV を1サンプルずつ組み立てる。状態はすべて `queue` の上でだけ触る。
///
/// サンプルの区切りはヘッダ行（`,interface,...`）。nettop はサンプルをまとめて書き出すので、
/// 出力が 0.25 秒途切れた時点でいったん送り、同じサンプルの続きが届いたら同じ日時で送り直す
/// （受け手はそれを「同じサンプルの更新」として扱う）。
nonisolated final class NettopParser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WiFiPulse.nettop", qos: .utility)
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var current: [NetProcess] = []
    private var currentDate = Date()
    private var dirty = false
    private var sampleCount = 0
    private let interval: Double
    private var totals: [Int32: (rx: Int64, tx: Int64, re: Int64)] = [:]
    private var connTotals: [String: (rx: Int64, tx: Int64, re: Int64)] = [:]
    private var flushItem: DispatchWorkItem?
    private let emit: @Sendable (ProcessSample) -> Void

    init(interval: Double, emit: @escaping @Sendable (ProcessSample) -> Void) {
        self.interval = interval
        self.emit = emit
    }

    /// fd から読み続ける。EOF・エラーで止まり、fd は閉じる。
    func attach(fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        src.setEventHandler { [weak self, weak src] in
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                // 疑似端末は相手が閉じると EIO になる。どちらも終わりとして扱う
                src?.cancel()
                return
            }
            self?.consume(Data(buf[0..<n]))
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    func detach() {
        queue.async {
            self.flushItem?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    /// テスト用: バイト列を直接流し込む
    func feed(_ data: Data) {
        queue.async { self.consume(data) }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line)
        }
        guard dirty else { return }
        flushItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushItem = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func handle(_ line: String) {
        if line.hasPrefix(",") {
            // 新しいサンプルの始まり。前のサンプルを確定させる
            flush()
            current.removeAll(keepingCapacity: true)
            sampleCount += 1
            currentDate = Date()
            if sampleCount % 150 == 0, connTotals.count > 5000 { connTotals.removeAll() }
            return
        }
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 9, sampleCount >= 1 else { return }
        let first = f[0]
        // 1回目のサンプルは -d でも起動時点までの累計なので、構造だけ読んで数値は使わない
        let useValues = sampleCount >= 2
        func int(_ i: Int) -> Int64 { useValues ? Int64(f[i]) ?? 0 : 0 }

        if let proto = ["tcp4", "tcp6", "udp4", "udp6"].first(where: { first.hasPrefix($0 + " ") }) {
            guard let pi = current.indices.last else { return }
            let pid = current[pi].pid
            let parts = first.dropFirst(proto.count + 1).components(separatedBy: "<->")
            guard parts.count == 2 else { return }
            let v6 = proto.hasSuffix("6")
            let (lh, lp) = Self.split(parts[0], v6: v6)
            let (rh, rp) = Self.split(parts[1], v6: v6)
            let id = "\(pid)|\(proto)|\(parts[0])|\(parts[1])"
            var c = NetConnection(id: id, proto: proto.hasPrefix("tcp") ? "TCP" : "UDP", family: v6 ? "IPv6" : "IPv4",
                                  localHost: lh, localPort: lp, remoteHost: rh, remotePort: rp)
            c.interface = String(f[1])
            c.state = String(f[2])
            let rx = int(3), tx = int(4), re = int(7)
            var t = connTotals[id] ?? (0, 0, 0)
            t.rx += rx; t.tx += tx; t.re += re
            connTotals[id] = t
            c.rxTotal = t.rx; c.txTotal = t.tx; c.retransmitTotal = t.re
            c.rxRate = Double(rx) / interval
            c.txRate = Double(tx) / interval
            c.rttMs = Double(f[8].replacingOccurrences(of: " ms", with: ""))
            current[pi].connections.append(c)
        } else {
            // プロセス行: "名前.pid"
            guard let dot = first.lastIndex(of: "."), let pid = Int32(first[first.index(after: dot)...]) else { return }
            let rx = int(3), tx = int(4), re = int(7)
            var t = totals[pid] ?? (0, 0, 0)
            t.rx += rx; t.tx += tx; t.re += re
            totals[pid] = t
            var p = NetProcess(pid: pid, name: String(first[..<dot]))
            p.rxRate = Double(rx) / interval
            p.txRate = Double(tx) / interval
            p.rxTotal = t.rx; p.txTotal = t.tx; p.retransmitTotal = t.re
            current.append(p)
        }
        dirty = true
    }

    private func flush() {
        flushItem?.cancel()
        guard dirty else { return }
        dirty = false
        if sampleCount >= 2, !current.isEmpty {
            emit(ProcessSample(date: currentDate, processes: current))
        }
    }

    /// "192.168.1.2:443" / "fe80::1%en0.55396" / "*:*" / "*.*"
    static func split(_ s: String, v6: Bool) -> (String, String) {
        let sep: Character = v6 ? "." : ":"
        guard let i = s.lastIndex(of: sep) else { return (s, "") }
        var host = String(s[..<i])
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        return (host, String(s[s.index(after: i)...]))
    }
}

/// 接続先IPの逆引き（キャッシュつき）。選択中のアプリの接続だけを引く。
actor HostNameCache {
    static let shared = HostNameCache()
    private var cache: [String: String?] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    /// 同じIPの問い合わせが重なったら、先に始まった方の結果を待つ
    func resolve(_ ip: String) async -> String? {
        if let c = cache[ip] { return c }
        if let t = inflight[ip] { return await t.value }
        let t = Task { await Self.lookup(ip) }
        inflight[ip] = t
        let name = await t.value
        cache[ip] = name
        inflight[ip] = nil
        return name
    }

    @concurrent
    private nonisolated static func lookup(_ ip: String) async -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
