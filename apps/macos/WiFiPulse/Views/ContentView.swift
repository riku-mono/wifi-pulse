import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, latency, connection, neighbors, processes, devices
    case speed, loadTest, events
    case report

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .latency: "Latency"
        case .connection: "Wi-Fi Connection"
        case .neighbors: "Nearby Wi-Fi"
        case .processes: "App Traffic"
        case .devices: "Local Devices"
        case .speed: "Speed Test"
        case .loadTest: "Load Test"
        case .events: "Wi-Fi Events"
        case .report: "Trends & Report"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .latency: "waveform.path.ecg"
        case .connection: "wifi"
        case .neighbors: "dot.radiowaves.left.and.right"
        case .processes: "app.connected.to.app.below.fill"
        case .devices: "laptopcomputer.and.iphone"
        case .speed: "speedometer"
        case .loadTest: "chart.line.uptrend.xyaxis"
        case .events: "list.bullet.rectangle"
        case .report: "calendar.day.timeline.left"
        }
    }

    /// ⌘1〜⌘9
    var shortcut: KeyEquivalent? {
        guard let i = SidebarItem.allCases.firstIndex(of: self), i < 9 else { return nil }
        return KeyEquivalent(Character(String(i + 1)))
    }

    static let sections: [(title: LocalizedStringKey, items: [SidebarItem])] = [
        ("Monitor", [.overview, .latency, .connection, .neighbors, .processes, .devices]),
        ("Diagnostics", [.speed, .loadTest, .events]),
        ("Records", [.report]),
    ]
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarItem.sections, id: \.items) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            SidebarRow(item: item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            DetailView(item: model.selection ?? .overview)
        }
    }
}

/// サブタイトル（ネットワーク名）は値が変わったときだけ更新される `networkTitle` を読む。
/// ここで毎秒変わる値を読むと、サイドバーを含むウインドウ全体が毎秒描き直されてしまう。
private struct DetailView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        Group {
            switch item {
            case .overview: OverviewView()
            case .latency: LatencyView()
            case .connection: WirelessView()
            case .neighbors: NeighborsView()
            case .processes: ProcessesView()
            case .devices: DevicesView()
            case .speed: SpeedTestView()
            case .loadTest: LoadTestView()
            case .events: EventsView()
            case .report: ReportView()
            }
        }
        .navigationSubtitle(model.monitor.networkTitle)
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.systemImage)
        }
        .badge(badge)
    }

    private var badge: Text? {
        switch item {
        case .devices:
            let n = model.monitor.devices.onlineCount
            return n > 0 ? Text("\(n)") : nil
        case .speed where model.speedTest.isRunning: return Text("Measuring")
        case .loadTest where model.loadTest.isRunning: return Text("Measuring")
        case .neighbors where model.neighbors.isScanning: return Text("Scanning")
        default: return nil
        }
    }
}

/// サイドバー下部の小さな常時表示（この部分だけが毎秒描き直される）
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let w = model.monitor.live.w30
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.up.forward")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Monitoring").font(.caption.weight(.semibold))
                Text("Router \(Fmt.ms(w.gw.p50)) ms · Internet \(Fmt.ms(w.v4.p50)) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
