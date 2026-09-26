import Foundation
import Synchronization

/// 1つの宛先に `/sbin/ping` を撃ち続け、到着した往復時間を溜めておく。
/// 取り出し（`drain`）は呼び出し側のタイミングで行う（1秒ごとの集計や、負荷試験のフェーズ境界）。
nonisolated final class Pinger: Sendable {
    struct Batch: Sendable, Hashable {
        var rtts: [Double] = []
        var lost: Int = 0
    }

    private struct State {
        var batch = Batch()
        var process: Process?
        var pending = ""
        var stopped = false
    }

    let host: String
    let interval: Double
    let v6: Bool
    private let state = Mutex(State())

    init(host: String, interval: Double, v6: Bool = false) {
        self.host = host
        self.interval = interval
        self.v6 = v6
    }

    func start() {
        state.withLock { $0.stopped = false }
        launch()
    }

    func stop() {
        let p = state.withLock { s -> Process? in
            s.stopped = true
            defer { s.process = nil }
            return s.process
        }
        if let p, p.isRunning { p.terminate() }
    }

    /// 前回からの結果を取り出して空にする。
    func drain() -> Batch {
        state.withLock { s in
            defer { s.batch = Batch() }
            return s.batch
        }
    }

    private func launch() {
        guard !host.isEmpty, !state.withLock({ $0.stopped }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: v6 ? "/sbin/ping6" : "/sbin/ping")
        process.arguments = ["-i", String(interval), host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.consume(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // 経路が消えた・一時的に失敗したなどで落ちたら、少し待って張り直す
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.launch() }
        }
        do {
            try process.run()
            state.withLock { $0.process = process }
        } catch {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.launch() }
        }
    }

    private func consume(_ chunk: String) {
        state.withLock { s in
            s.pending += chunk
            while let nl = s.pending.firstIndex(of: "\n") {
                let line = s.pending[..<nl]
                s.pending = String(s.pending[s.pending.index(after: nl)...])
                if let rtt = Self.parseRTT(line) {
                    s.batch.rtts.append(rtt)
                } else if line.hasPrefix("Request timeout") {
                    s.batch.lost += 1
                }
            }
        }
    }

    /// `64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms` から往復時間を取り出す。
    static func parseRTT(_ line: Substring) -> Double? {
        guard line.contains("icmp_seq"), let r = line.range(of: "time=") ?? line.range(of: "time<") else { return nil }
        let rest = line[r.upperBound...]
        let num = rest.prefix { $0.isNumber || $0 == "." }
        return Double(num).map { ($0 * 100).rounded() / 100 }
    }
}
