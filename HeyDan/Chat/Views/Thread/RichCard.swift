import Charts
import HeyDanCore
import SwiftUI

extension AXID {
    static func card(_ messageID: String) -> String { "chat.card.\(messageID)" }
}

struct RichCard: View {
    @Environment(\.theme) private var theme
    let card: Card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.bubble)
        VStack(alignment: .leading, spacing: theme.space.s4) {
            if card.title != nil || card.description != nil {
                VStack(alignment: .leading, spacing: theme.space.s1) {
                    if let title = card.title {
                        Text(title).textRole(theme.type.headline, theme.weight.bold)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let description = card.description {
                        Text(description).foregroundStyle(theme.color.textSecondary)
                    }
                }
            }
            ForEach(card.parts.indices, id: \.self) { index in part(card.parts[index]) }
            if !card.actions.isEmpty {
                VStack(spacing: theme.space.s2) {
                    ForEach(card.actions.indices, id: \.self) { index in
                        let action = card.actions[index]
                        if let url = action.webURL { link(action, url: url) }
                    }
                }
            }
        }
        .textRole(theme.type.footnote)
        .foregroundStyle(theme.color.textPrimary)
        .padding(theme.space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color.surfaceCard, in: shape)
        .overlay { shape.strokeBorder(theme.color.border) }
    }

    @ViewBuilder private func part(_ part: CardPart) -> some View {
        switch part {
        case .fields(let fields):
            let column = GridItem(.flexible(), spacing: theme.space.s4, alignment: .topLeading)
            LazyVGrid(columns: [column, column], alignment: .leading, spacing: theme.space.s3) {
                ForEach(fields.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: theme.space.s0_5) {
                        Text(fields[index].label).textRole(theme.type.caption).foregroundStyle(theme.color.textTertiary)
                        Text(fields[index].value).textRole(theme.type.footnote, theme.weight.medium)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case let .table(headers, rows, align, caption):
            CardTable(headers: headers, rows: rows, align: align ?? [], caption: caption)
        case let .chart(title, chart):
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(title).textRole(theme.type.label, theme.weight.bold)
                CardPlot(chart: chart)
            }
        case .divider:
            Divider().overlay(theme.color.border)
        case let .text(content, style):
            Text(content)
                .textRole(theme.type.footnote, style == "bold" ? theme.weight.bold : theme.weight.regular)
                .foregroundStyle(style == "muted" ? theme.color.textSecondary : theme.color.textPrimary)
        }
    }

    private func link(_ action: CardAction, url: URL) -> some View {
        let (ink, fill) = switch action.style {
        case "primary": (theme.color.onAccent, theme.color.accent)
        case "danger": (theme.color.danger, theme.color.dangerSurface)
        default: (theme.color.textPrimary, theme.color.secondaryFill)
        }
        return Link(destination: url) {
            Text(action.label)
                .textRole(theme.type.footnote, theme.weight.medium)
                .multilineTextAlignment(.center)
                .foregroundStyle(ink)
                .padding(.horizontal, theme.space.s4)
                .padding(.vertical, theme.space.s2)
                .frame(maxWidth: .infinity, minHeight: theme.space.s10)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CardTable: View {
    @Environment(\.theme) private var theme
    let headers: [String]
    let rows: [[String]]
    let align: [String]
    let caption: String?
    @State private var overflows = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.xs)
        VStack(alignment: .leading, spacing: theme.space.s1_5) {
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    row(headers, header: true)
                    ForEach(rows.indices, id: \.self) { row(rows[$0], header: false) }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > $0.containerSize.width } action: { _, value in
                overflows = value
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.color.border) }
            HStack(spacing: theme.space.s1) {
                if let caption { Text(caption) }
                if overflows {
                    Text("Scrolls sideways")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .textRole(theme.type.caption).foregroundStyle(theme.color.textTertiary)
        }
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { index in
                let alignment: Alignment = switch align.indices.contains(index) ? align[index] : "left" {
                case "right": .trailing
                case "center": .center
                default: .leading
                }
                Text(cells[index])
                    .textRole(theme.type.caption, header ? theme.weight.bold : theme.weight.regular)
                    .foregroundStyle(header ? theme.color.textPrimary : theme.color.textSecondary)
                    .padding(.horizontal, theme.space.s2_5)
                    .padding(.vertical, theme.space.s1_5)
                    .frame(minWidth: index == 0 ? 70 : 80, alignment: alignment)
                    .gridColumnAlignment(alignment.horizontal)
            }
        }
        .background(header ? theme.color.surfaceGrouped : theme.color.surfaceCard)
        .overlay(alignment: .bottom) { Divider().overlay(theme.color.border) }
    }
}

private struct CardPlot: View {
    @Environment(\.theme) private var theme
    let chart: CardChart

    private func color(_ index: Int) -> Color {
        let colors = [theme.color.accent, theme.color.statusWorking, theme.color.statusDone,
                      theme.color.warning, theme.color.danger, theme.color.statusInput]
        return colors[index % colors.count]
    }

    var body: some View {
        switch chart {
        case .pie(let segments):
            let total = segments.reduce(0) { $0 + max(0, $1.value) }
            HStack(spacing: theme.space.s4) {
                Chart {
                    ForEach(segments.indices, id: \.self) { index in
                        if segments[index].value > 0 {
                            SectorMark(angle: .value("Value", segments[index].value))
                                .foregroundStyle(color(index))
                                .accessibilityLabel(segments[index].label)
                        }
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: theme.space.s1_5) {
                    ForEach(segments.indices, id: \.self) { index in
                        let share = total > 0 ? max(0, segments[index].value) / total : 0
                        legendItem("\(segments[index].label)  \(share.formatted(.percent))", index: index)
                    }
                }
            }
        case let .plot(type, categories, series):
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Chart {
                    ForEach(series.indices, id: \.self) { s in
                        ForEach(0..<min(categories.count, series[s].values.count), id: \.self) { i in
                            let x = PlottableValue.value("Category", String(i))
                            let y = PlottableValue.value(series[s].name, series[s].values[i])
                            let group = PlottableValue.value("Series", String(s))
                            switch type {
                            case .bar:
                                BarMark(x: x, y: y).position(by: group)
                                    .foregroundStyle(color(s)).cornerRadius(theme.space.s1)
                                    .accessibilityLabel(categories[i])
                            case .area:
                                AreaMark(x: x, y: y, series: group, stacking: .unstacked)
                                    .foregroundStyle(s == 0 ? theme.color.accentSoft : color(s).opacity(0.12))
                                    .accessibilityLabel(categories[i])
                                LineMark(x: x, y: y, series: group).foregroundStyle(color(s))
                                    .accessibilityHidden(true)
                            case .line:
                                LineMark(x: x, y: y, series: group).foregroundStyle(color(s))
                                    .accessibilityLabel(categories[i])
                            }
                        }
                    }
                }
                .chartXScale(domain: categories.indices.map { String($0) })
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        if let key = value.as(String.self), let index = Int(key), categories.indices.contains(index) {
                            AxisValueLabel {
                                Text(categories[index]).textRole(theme.type.micro).foregroundStyle(theme.color.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: type == .bar ? 128 : 90)
                if series.count > 1 {
                    FlowLayout(spacing: theme.space.s3, lineSpacing: theme.space.s1_5) {
                        ForEach(series.indices, id: \.self) { legendItem(series[$0].name, index: $0) }
                    }
                }
            }
        }
    }

    private func legendItem(_ label: String, index: Int) -> some View {
        HStack(spacing: theme.space.s1_5) {
            Circle().fill(color(index)).frame(width: theme.space.s2, height: theme.space.s2)
            Text(label).textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
        }
    }
}
