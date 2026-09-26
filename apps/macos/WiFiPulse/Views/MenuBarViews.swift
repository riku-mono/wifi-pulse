import SwiftUI

/// メニューバーのアイコン。`menu`（変化したときだけ更新）しか読まないので、毎秒は描き直されない。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.monitor.menu
        Group {
            if !m.connected {
                Image(systemName: "wifi.slash")
            } else if m.level == .crit {
                Image(systemName: "wifi.exclamationmark")
            } else {
                Image(systemName: "wifi", variableValue: Double(m.bars) / 4)
            }
        }
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

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ScoreRing(score: s.score, level: s.level, lineWidth: 6)
                    .frame(width: 64, height: 64)
                    .scaleEffect(0.62)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.verdict).font(.title3.weight(.bold))
                    Text(s.link?.ssid ?? m.pathStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                LevelBadge(text: s.bottleneck.tag, level: s.bottleneck.level).font(.caption)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("wifi", "電波", s.link.map { "\($0.rssi) dBm · \($0.bandLabel) ch\($0.channel ?? 0)" } ?? "—", Level.rssi(s.link?.rssi))
                row("wifi.router", "ルーター", "\(Fmt.ms(s.w30.gw.p50)) ms（p95 \(Fmt.ms(s.w60.gw.p95))）", Level.gateway(s.w30.gw.p95))
                row("globe.asia.australia", "ネット", "\(Fmt.ms(s.w30.v4.p50)) ms（p95 \(Fmt.ms(s.w60.v4.p95))）", Level.internet(s.w30.v4.p95))
                row("waveform", "ロス", "\(Fmt.pct(s.w60.worstLoss))%", Level.loss(s.w60.worstLoss))
                row("arrow.up.arrow.down", "通信量", "↓\(Fmt.mbps(s.rx)) ↑\(Fmt.mbps(s.tx)) Mbps", .none)
            }
            .font(.callout)

            RecentLatencyChart(seconds: 90, compact: true)
                .frame(height: 70)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        openMain(.overview)
                    } label: {
                        Label("ウインドウを開く", systemImage: "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        openMain(.speed)
                        Task { await model.speedTest.run(interface: m.env.interface) }
                    } label: {
                        Label("速度", systemImage: "speedometer")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.speedTest.isRunning)
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.glass)
                    .help("Wi-Fi Pulse を終了（常時計測も止まります）")
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ level: Level) -> some View {
        GridRow {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
            Image(systemName: level.symbol)
                .foregroundStyle(level.tint)
                .opacity(level == .none ? 0 : 1)
                .accessibilityLabel(level.accessibilityText)
        }
    }

    private func openMain(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: "main")
        NSApp.activate()
    }
}
