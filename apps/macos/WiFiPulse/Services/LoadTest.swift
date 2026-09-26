import Foundation
import Observation

/// 回線をわざと埋めて、そのとき遅延がどこまで跳ねるかを測る（バッファブロート試験）。
/// ルーター宛てとインターネット宛てを同時に測るので「待たされているのがWi-Fi区間か回線側か」まで分かる。
@Observable
final class LoadTest {
    enum Mode: String, CaseIterable, Identifiable {
        case both, down, up
        var id: Self { self }
        var label: String {
            switch self {
            case .both: String(localized: "Download + Upload")
            case .down: String(localized: "Download Only")
            case .up: String(localized: "Upload Only")
            }
        }
    }

    struct PhasePlan: Identifiable, Hashable {
        var id: String { key }
        let key: String
        let title: String
        let seconds: Int
        let load: LoadStream.Direction?
    }

    struct LivePoint: Identifiable {
        let id = UUID()
        let elapsed: Double
        let series: String
        let ms: Double
    }

    struct Grade: Hashable {
        let letter: String
        let note: String

        var level: Level {
            switch letter {
            case "A+", "A": .good
            case "B", "C": .warn
            case "D", "F": .crit
            default: .none
            }
        }
    }

    // 設定
    var mode: Mode = .both
    var duration = 20
    var streams = 6
    var target = "1.1.1.1"

    // 状態
    private(set) var isRunning = false
    private(set) var plan: [PhasePlan] = []
    private(set) var currentPhase: String?
    private(set) var phaseProgress = 0.0
    private(set) var live: [LivePoint] = []
    private(set) var liveThroughput: (rx: Double, tx: Double) = (0, 0)
    private(set) var result: LoadTestRecord?
    private(set) var history: [LoadTestRecord] = []
    private(set) var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        history = DataStore.load(DataStore.loadtests, as: LoadTestRecord.self)
        result = history.last
    }

    nonisolated static let downURL = URL(string: "https://speed.cloudflare.com/__down?bytes=500000000")!
    nonisolated static let upURL = URL(string: "https://speed.cloudflare.com/__up")!

    var totalSeconds: Int { makePlan().reduce(0) { $0 + $1.seconds + ($1.load == nil ? 0 : 2) } }

    func makePlan() -> [PhasePlan] {
        var p = [PhasePlan(key: "idle", title: String(localized: "Idle"), seconds: max(10, duration / 2), load: nil)]
        if mode != .up {
            p.append(PhasePlan(key: "down", title: String(localized: "Saturate Download"), seconds: duration, load: .down))
            p.append(PhasePlan(key: "rest1", title: String(localized: "Recovery"), seconds: 8, load: nil))
        }
        if mode != .down {
            p.append(PhasePlan(key: "up", title: String(localized: "Saturate Upload"), seconds: duration, load: .up))
        }
        return p
    }

    func start(env: NetworkEnvironment) {
        guard !isRunning else { return }
        guard !env.gateway.isEmpty else {
            error = String(localized: "No default gateway found. Are you connected to a network?")
            return
        }
        task = Task { await run(env: env) }
    }

    func cancel() { task?.cancel() }

    private func run(env: NetworkEnvironment) async {
        isRunning = true
        error = nil
        live = []
        plan = makePlan()
        let started = Date()
        let gw = Pinger(host: env.gateway, interval: 0.2)
        let inet = Pinger(host: target, interval: 0.2)
        gw.start(); inet.start()
        defer {
            gw.stop(); inet.stop()
            isRunning = false
            currentPhase = nil
        }
        try? await Task.sleep(for: .seconds(1.5))

        // 24MB。圧縮されないようランダムに埋める
        var payload = Data(count: 24 << 20)
        payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        var phases: [String: LoadTestRecord.Phase] = [:]

        for step in plan {
            if Task.isCancelled { break }
            currentPhase = step.key
            phaseProgress = 0
            _ = gw.drain(); _ = inet.drain()
            var gwRtts: [Double] = [], gwLost = 0, inRtts: [Double] = [], inLost = 0
            let b0 = InterfaceCounters.read(env.interface)
            let t0 = Date()
            var loads: [LoadStream] = []
            if let dir = step.load {
                loads = (0..<streams).map { _ in LoadStream(direction: dir, payload: dir == .up ? payload : nil) }
                loads.forEach { $0.start() }
            }
            let total = Double(step.seconds + (step.load == nil ? 0 : 2))
            var prev = b0, prevAt = t0
            while Date().timeIntervalSince(t0) < total, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let g = gw.drain(), i = inet.drain()
                gwRtts += g.rtts; gwLost += g.lost; inRtts += i.rtts; inLost += i.lost
                let el = Date().timeIntervalSince(started)
                if let m = g.rtts.max() { live.append(LivePoint(elapsed: el, series: SeriesName.router, ms: m)) }
                if let m = i.rtts.max() { live.append(LivePoint(elapsed: el, series: SeriesName.internet, ms: m)) }
                if let cur = InterfaceCounters.read(env.interface), let p = prev {
                    let dt = Date().timeIntervalSince(prevAt)
                    liveThroughput = (Double(cur.rx &- p.rx) * 8 / dt, Double(cur.tx &- p.tx) * 8 / dt)
                    prev = cur; prevAt = Date()
                }
                phaseProgress = min(1, Date().timeIntervalSince(t0) / total)
            }
            loads.forEach { $0.stop() }
            let dt = Date().timeIntervalSince(t0)
            var ph = LoadTestRecord.Phase(gw: PingStats(gwRtts, lost: gwLost).rounded, inet: PingStats(inRtts, lost: inLost).rounded)
            if let b0, let b1 = InterfaceCounters.read(env.interface), dt > 0 {
                ph.rx_mbps = (Double(b1.rx &- b0.rx) * 8 / dt / 1e5).rounded() / 10
                ph.tx_mbps = (Double(b1.tx &- b0.tx) * 8 / dt / 1e5).rounded() / 10
            }
            phases[step.key] = ph
        }
        liveThroughput = (0, 0)

        guard !Task.isCancelled else {
            error = String(localized: "Cancelled")
            return
        }

        let idle = phases["idle"]?.inet?.p50
        var verdict: [String: LoadTestRecord.Verdict] = [:]
        for key in ["down", "up"] {
            guard let ph = phases[key] else { continue }
            verdict[key] = .init(grade: Self.grade(idleP50: idle, loadedP95: ph.inet?.p95).letter,
                                 inet_p95: ph.inet?.p95, gw_p95: ph.gw?.p95)
        }
        let order = ["A+", "A", "B", "C", "D", "F", "?"]
        let worst = verdict.values.map(\.grade).max { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        let rec = LoadTestRecord(t: started.epochMs, iface: env.interface, gw: env.gateway, target: target,
                                 duration: duration, streams: streams, phases: phases,
                                 verdict: verdict, worst_grade: worst ?? "?", net: env.networkID)
        DataStore.append(rec, to: DataStore.loadtests)
        history.append(rec)
        result = rec
    }

    /// 無負荷時からの増加量で採点（DSLReports 方式に近い）。
    static func grade(idleP50: Double?, loadedP95: Double?) -> Grade {
        guard let idle = idleP50, let loaded = loadedP95 else { return Grade(letter: "?", note: String(localized: "Couldn’t measure")) }
        let d = loaded - idle
        return switch d {
        case ..<5: Grade(letter: "A+", note: String(localized: "Barely increases. Ideal"))
        case ..<30: Grade(letter: "A", note: String(localized: "Good. No effect on calls or games"))
        case ..<60: Grade(letter: "B", note: String(localized: "Slight. Audio may cut out briefly"))
        case ..<200: Grade(letter: "C", note: String(localized: "Noticeable. Calls break up during downloads"))
        case ..<400: Grade(letter: "D", note: String(localized: "Bad. Calls and games lag by hundreds of milliseconds to a second"))
        default: Grade(letter: "F", note: String(localized: "Very bad. Other traffic stalls for seconds during transfers"))
        }
    }

    /// 詰まっている区間の説明
    static func bottleneckNote(record: LoadTestRecord, key: String) -> String? {
        guard let v = record.verdict?[key], let gw95 = v.gw_p95, v.inet_p95 != nil,
              let idleGw = record.phases["idle"]?.gw?.p50, !["A+", "A"].contains(v.grade) else { return nil }
        return gw95 > idleGw + 100
            ? String(localized: "Even pings to the router are delayed, so the congestion is on the Wi-Fi segment or in the router itself. Suspect the signal, the channel, or the router’s processing power.")
            : String(localized: "The router responds quickly but the Internet is slow, so the queue on the WAN side is congested. Enabling QoS/SQM on your router, or limiting upload bandwidth to about 90% of the actual speed, will help.")
    }
}

extension PingStats {
    /// 保存用に小数1桁へ丸める
    nonisolated var rounded: PingStats {
        func r(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }
        return PingStats(n: n, lost: lost, min: r(min), p50: r(p50), p95: r(p95), p99: r(p99), max: r(max), jitter: r(jitter))
    }
}

/// 1本のHTTP接続で回線を埋め続ける。受け取ったデータは捨てる。
nonisolated final class LoadStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Direction: Hashable, Sendable { case down, up }

    let direction: Direction
    let payload: Data?
    private let lock = NSLock()
    private var running = false
    private var session: URLSession?

    init(direction: Direction, payload: Data?) {
        self.direction = direction
        self.payload = payload
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        lock.withLock { running = true; session = s }
        next()
    }

    func stop() {
        let s = lock.withLock { () -> URLSession? in running = false; return session }
        s?.invalidateAndCancel()
    }

    private func next() {
        guard let s = lock.withLock({ running ? session : nil }) else { return }
        switch direction {
        case .down:
            s.dataTask(with: LoadTest.downURL).resume()
        case .up:
            var req = URLRequest(url: LoadTest.upURL)
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            s.uploadTask(with: req, from: payload ?? Data()).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        next()
    }
}
