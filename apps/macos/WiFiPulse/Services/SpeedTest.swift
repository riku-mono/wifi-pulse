import Foundation
import Observation

/// macOS 標準の `networkQuality` で速度と応答性（RPM）を測る。
@Observable
final class SpeedTest {
    enum State: Equatable {
        case idle, running(started: Date), failed(String)
    }

    private(set) var state: State = .idle
    private(set) var history: [SpeedTestRecord] = []
    private(set) var latest: SpeedTestRecord?

    init() {
        reload()
    }

    var isRunning: Bool { if case .running = state { true } else { false } }

    func reload() {
        history = DataStore.load(DataStore.speedtests, as: SpeedTestRecord.self)
        latest = history.last
    }

    func run(env: NetworkEnvironment) async {
        guard !isRunning else { return }
        state = .running(started: Date())
        let out = await Shell.run("/usr/bin/networkQuality", ["-s", "-c", "-I", env.interface], timeout: 150)
        guard let data = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (j["dl_throughput"] as? NSNumber)?.doubleValue, dl > 0 else {
            state = .failed(String(localized: "networkQuality failed. Check your network connection."))
            return
        }
        let now = Date()
        let rec = SpeedTestRecord(
            t: now.epochMs, hour: now.hour, wd: now.pythonWeekday,
            dl: (dl / 1e5).rounded() / 10,
            ul: (((j["ul_throughput"] as? NSNumber)?.doubleValue ?? 0) / 1e5).rounded() / 10,
            dl_rpm: (j["dl_responsiveness"] as? NSNumber)?.doubleValue,
            ul_rpm: (j["ul_responsiveness"] as? NSNumber)?.doubleValue,
            base_rtt: (j["base_rtt"] as? NSNumber)?.doubleValue,
            net: env.networkID
        )
        DataStore.append(rec, to: DataStore.speedtests)
        history.append(rec)
        latest = rec
        state = .idle
    }
}
