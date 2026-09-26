import SwiftUI

/// メニューバーのアイコン。`menu`（変化したときだけ更新）しか読まないので、毎秒は描き直されない。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: model.monitor.menu))
            .accessibilityLabel("Wi-Fi Pulse")
    }
}

/// メニューバーから開く小さなパネル。開いている間だけ毎秒描き直される。
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let m = model.monitor
        let s = m.live

        VStack(alignment: .leading, spacing: 12) {
            MenuBarSummary(live: s, subtitle: s.link?.ssid ?? m.pathStatus)

            RecentLatencyChart(seconds: 90, compact: true)
                .frame(height: 70)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        openMain(.overview)
                    } label: {
                        Label("Open Window", systemImage: "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        openMain(.speed)
                        Task { await model.speedTest.run(env: m.env) }
                    } label: {
                        Label("Speed", systemImage: "speedometer")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.speedTest.isRunning)
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.glass)
                    .help("Quit Wi-Fi Pulse (continuous monitoring stops too)")
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func openMain(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// パネルの上半分（スコアと各項目）。モデルに触らず `LiveSnapshot` だけから描く
struct MenuBarSummary: View {
    let live: LiveSnapshot
    let subtitle: String

    var body: some View {
        let s = live
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ScoreRing(score: s.score, level: s.level, lineWidth: 5)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.verdict)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                LevelBadge(text: s.bottleneck.tag, level: s.bottleneck.level, compact: true)
                    .fixedSize()
            }

            // 判定の記号と表示する p95 は同じ窓（直近30秒）から出す
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("wifi", "Signal", s.link.map { "\($0.rssi) dBm · \($0.bandLabel) ch\($0.channel ?? 0)" } ?? "—", Level.rssi(s.link?.rssi))
                row("wifi.router", "Router", String(localized: "\(Fmt.ms(s.w30.gw.p50)) ms (p95 \(Fmt.ms(s.w30.gw.p95)))"), Level.gateway(s.w30.gw.p95))
                row("globe.asia.australia", "Internet", String(localized: "\(Fmt.ms(s.w30.v4.p50)) ms (p95 \(Fmt.ms(s.w30.v4.p95)))"), Level.internet(s.w30.v4.p95))
                row("waveform", "Loss", "\(Fmt.pct(s.w60.worstLoss))%", Level.loss(s.w60.worstLoss))
                row("arrow.up.arrow.down", "Traffic", "↓\(Fmt.mbps(s.rx)) ↑\(Fmt.mbps(s.tx)) Mbps", .none)
            }
            .font(.callout)
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: String, _ level: Level) -> some View {
        GridRow {
            // 記号ごとに幅が違うので、列の幅を固定して項目名の左端をそろえる
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
            Image(systemName: level.symbol)
                .foregroundStyle(level.tint)
                .opacity(level == .none ? 0 : 1)
                .accessibilityLabel(level.accessibilityText)
        }
    }
}
