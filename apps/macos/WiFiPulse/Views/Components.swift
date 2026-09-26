import SwiftUI

/// コンテンツ層のカード。Liquid Glass はナビゲーションやコントロール層に任せ、
/// 中身は落ち着いた塗りで区切る（HIG: ガラスをコンテンツに重ねない）。
struct Card<Content: View, Accessory: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, systemImage: String? = nil, subtitle: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            if let systemImage {
                                Label(title, systemImage: systemImage).font(.headline)
                            } else {
                                Text(title).font(.headline)
                            }
                        }
                        if let subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    accessory
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

/// 1つの指標。色だけに頼らないよう、記号と文言を必ず添える。
struct MetricTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    var level: Level = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if level != .none {
                    Image(systemName: level.symbol)
                        .foregroundStyle(level.tint)
                        .accessibilityLabel(level.accessibilityText)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct LevelBadge: View {
    let text: String
    let level: Level

    var body: some View {
        Label(text, systemImage: level.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(level.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(level.tint.opacity(0.14), in: .capsule)
    }
}

/// 総合スコアのリング
struct ScoreRing: View {
    let score: Int?
    let level: Level
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(level.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ 100").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("総合スコア")
        .accessibilityValue(score.map { "\($0)点" } ?? "測定中")
    }
}

struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < bars ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: CGFloat(6 + i * 5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 観測・所見の1行
struct ObservationRow: View {
    let level: Level
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: level.symbol)
                .foregroundStyle(level.tint)
                .accessibilityLabel(level.accessibilityText)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// ping 統計の表
struct PingStatsGrid: View {
    let rows: [(String, PingStats)]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("宛先").gridColumnAlignment(.leading)
                Text("中央値"); Text("p95"); Text("p99"); Text("最大"); Text("ゆらぎ"); Text("ロス")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows, id: \.0) { name, s in
                GridRow {
                    Text(name).gridColumnAlignment(.leading).lineLimit(1)
                    Text(Fmt.ms(s.p50))
                    Text(Fmt.ms(s.p95))
                    Text(Fmt.ms(s.p99))
                    Text(Fmt.ms(s.max)).foregroundStyle((s.max ?? 0) > 500 ? Level.crit.tint : .primary)
                    Text(Fmt.ms(s.jitter))
                    Text(s.n + s.lost == 0 ? "—" : "\(Fmt.pct(s.loss))%")
                        .foregroundStyle(Level.loss(s.loss).tint)
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }
}

extension Level {
    var accessibilityText: String {
        switch self {
        case .none: "判定なし"
        case .good: "良好"
        case .warn: "注意"
        case .crit: "要対応"
        }
    }
}

/// チャートの系列色。Wi-Fi区間（ルーター）とインターネットを常に同じ色で示す。
enum SeriesColor {
    static let router = Color.teal
    static let inet4 = Color.indigo
    static let inet6 = Color.purple
    static let rx = Color.blue
    static let tx = Color.orange
}
