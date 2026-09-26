import Charts
import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ev = model.events
        Group {
            if let r = ev.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(r)
                        timeline(r)
                        HStack(alignment: .top, spacing: 16) {
                            requesters(r)
                            awdl(r)
                        }
                        details(r)
                    }
                    .padding(24)
                }
            } else if ev.isLoading {
                ProgressView("Reading the unified log… (this can take a few tens of seconds)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Load Wi-Fi Events", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Extracts events from the macOS unified log that can cause latency spikes — disconnects, roaming, scans, radar detection (DFS), and AWDL. Load it right after you notice a problem.")
                } actions: {
                    Button("Load") { Task { await ev.load() } }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Wi-Fi Events")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Period", selection: $ev.span) {
                    ForEach(WiFiEvents.Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await ev.load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(ev.isLoading)
            }
        }
    }

    private func summary(_ r: WiFiEvents.Report) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(WiFiEvents.Category.allCases) { c in
                let n = r.counts[c] ?? 0
                MetricTile(title: LocalizedStringKey(c.title), systemImage: c.symbol, value: "\(n)", unit: String(localized: "unit.events", defaultValue: "", comment: "件数の単位。英語では付けない"),
                           caption: c == .scan ? String(localized: "Live scans: \(r.liveScans)") : nil,
                           level: level(c, n))
            }
        }
    }

    private func level(_ c: WiFiEvents.Category, _ n: Int) -> Level {
        switch c {
        case .disconnect, .dfs: n > 0 ? .crit : .good
        case .roam: n > 10 ? .warn : .none
        case .btcoex: n > 20 ? .warn : .none
        default: .none
        }
    }

    private func timeline(_ r: WiFiEvents.Report) -> some View {
        let shown: Set<WiFiEvents.Category> = [.disconnect, .roam, .scan, .dfs]
        return Card("Events per 10 minutes", systemImage: "chart.bar.xaxis",
                    subtitle: String(localized: "Last \(ev_label(r.span)) · \(r.lineCount) log lines analyzed · Retrieved \(Fmt.time(r.generated))")) {
            Chart(r.buckets.filter { shown.contains($0.category) }) { b in
                BarMark(x: .value("Time", b.start, unit: .minute), y: .value("Count", b.count), width: .ratio(0.85))
                    .foregroundStyle(by: .value("Type", b.category.title))
            }
            .chartForegroundStyleScale([
                WiFiEvents.Category.disconnect.title: Color.red,
                WiFiEvents.Category.dfs.title: Color.orange,
                WiFiEvents.Category.roam.title: Color.purple,
                WiFiEvents.Category.scan.title: Color.teal,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 200)
        }
    }

    private func ev_label(_ span: String) -> String {
        WiFiEvents.Span(rawValue: span)?.label ?? span
    }

    private func requesters(_ r: WiFiEvents.Report) -> some View {
        Card("Who Requested Scans", systemImage: "person.crop.circle.badge.questionmark") {
            if r.requesters.isEmpty {
                Text("No scan requests found").foregroundStyle(.secondary)
            } else {
                let top = r.requesters.first?.count ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(r.requesters, id: \.name) { item in
                        HStack {
                            Text(item.name).font(.callout.monospaced()).frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(.teal.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                            }
                            .frame(height: 8)
                            Text("\(item.count)").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Text("locationd = Location Services, sharingd = AirDrop discovery. Monitoring tools and system_profiler can also trigger scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func awdl(_ r: WiFiEvents.Report) -> some View {
        let up = r.awdlState.contains("UP") && r.awdlState.contains("RUNNING")
        return Card("AWDL Status", systemImage: "airplayaudio") {
            LevelBadge(text: up ? String(localized: "Active") : String(localized: "Inactive"), level: up ? .warn : .good)
            Text(WiFiEvents.Category.awdl.explanation).font(.callout)
            Text("To isolate it, temporarily disable it in Terminal during a call (AirDrop, Sidecar, and Handoff stop working; restarting also restores it):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("sudo ifconfig awdl0 down\nsudo ifconfig awdl0 up")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: .rect(cornerRadius: 8))
        }
    }

    private func details(_ r: WiFiEvents.Report) -> some View {
        Card("Explanations and Log Lines by Type", systemImage: "text.magnifyingglass") {
            ForEach(WiFiEvents.Category.allCases) { c in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(c.explanation).font(.callout)
                        if let lines = r.samples[c], !lines.isEmpty {
                            ScrollView(.horizontal) {
                                Text(lines.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .background(.background, in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    Label("\(c.title) (\(r.counts[c] ?? 0))", systemImage: c.symbol)
                }
            }
        }
    }
}
