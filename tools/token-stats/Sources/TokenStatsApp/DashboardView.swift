import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @StateObject private var store = UsageStore()
    @State private var selectedRange: DashboardRange = .thirtyDays
    @State private var selectedMetric: DashboardMetric = .tokens
    @State private var enabledProviders = Set(UsageProvider.allCases)
    @State private var exportError: String?
    @State private var snapshot = DashboardSnapshot.empty
    @State private var snapshotTask: Task<Void, Never>?
    @State private var isPreparingSnapshot = false

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.052, blue: 0.065).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let error = store.errorMessage {
                        warning(message: error)
                    }
                    if store.records.isEmpty, !store.isLoading {
                        emptyState
                    } else {
                        summaryRow
                        chartCard
                        breakdownRow
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(.dark)
        .task { store.refresh() }
        .onReceive(store.$records) { records in
            rebuildSnapshot(records: records)
        }
        .onChange(of: selectedRange) {
            rebuildSnapshot()
        }
        .onChange(of: enabledProviders) {
            rebuildSnapshot()
        }
        .alert("Could not export image", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Token Stats")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("What the models processed, and what it would have cost at API rates.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $selectedRange) {
                ForEach(DashboardRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 310)
            Button {
                exportDashboard()
            } label: {
                Label("Export PNG", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.16))
            Button {
                store.refresh()
            } label: {
                if store.isLoading || isPreparingSnapshot {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .help("Refresh local usage")
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 14) {
            StatCard(
                title: "Total tokens",
                value: TokenFormat.compact(snapshot.totalTokens),
                detail: "\(snapshot.records.count.formatted()) usage samples",
                symbol: "sum",
                color: .white
            )
            StatCard(
                title: "API equivalent",
                value: TokenFormat.currency(snapshot.totalCostUSD),
                detail: "USD at public list prices",
                symbol: "dollarsign.circle.fill",
                color: Color(red: 0.43, green: 0.82, blue: 0.58)
            )
            StatCard(
                title: "Cached input",
                value: TokenFormat.compact(snapshot.cachedTokens),
                detail: snapshot.totalTokens == 0 ? "0% of all tokens" : "\(Int((Double(snapshot.cachedTokens) / Double(snapshot.totalTokens)) * 100))% of all tokens",
                symbol: "bolt.horizontal.circle.fill",
                color: Color(red: 0.38, green: 0.68, blue: 1.0)
            )
            StatCard(
                title: "Active days",
                value: snapshot.activeDays.formatted(),
                detail: dateRangeLabel,
                symbol: "calendar",
                color: Color(red: 0.76, green: 0.58, blue: 1.0)
            )
        }
    }

    private var dateRangeLabel: String {
        "\(snapshot.rangeStart.formatted(.dateTime.day().month(.abbreviated))) to \(snapshot.rangeEnd.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedMetric == .tokens ? "Daily token usage" : "Daily API-equivalent cost")
                        .font(.title3.weight(.semibold))
                    Text("Click a provider below to show or hide it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(DashboardMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 245)
            }

            Chart(snapshot.points) { point in
                AreaMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(selectedMetric.rawValue, chartValue(point)),
                    series: .value("Provider", point.provider.rawValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [point.provider.color.opacity(0.28), point.provider.color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(selectedMetric.rawValue, chartValue(point)),
                    series: .value("Provider", point.provider.rawValue)
                )
                .foregroundStyle(by: .value("Provider", point.provider.rawValue))
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(
                domain: UsageProvider.allCases.map(\.rawValue),
                range: UsageProvider.allCases.map(\.color)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.10))
                    AxisValueLabel {
                        if selectedMetric == .tokens, let intValue = value.as(Int.self) {
                            Text(TokenFormat.compact(intValue))
                        } else if let doubleValue = value.as(Double.self) {
                            Text(TokenFormat.currency(doubleValue))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 280)

            HStack(spacing: 10) {
                ForEach(UsageProvider.allCases) { provider in
                    ProviderToggle(
                        provider: provider,
                        summary: snapshot.providerSummaries.first { $0.provider == provider },
                        isEnabled: enabledProviders.contains(provider)
                    ) {
                        if enabledProviders.contains(provider) {
                            if enabledProviders.count > 1 { enabledProviders.remove(provider) }
                        } else {
                            enabledProviders.insert(provider)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private func chartValue(_ point: DailyUsagePoint) -> Double {
        selectedMetric == .tokens ? Double(point.tokens) : point.costUSD
    }

    private var breakdownRow: some View {
        HStack(alignment: .top, spacing: 14) {
            modelBreakdown
            dataSources
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Models")
                .font(.title3.weight(.semibold))
            let models = snapshot.modelSummaries
            if models.isEmpty {
                Text("No model usage in this range.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(models.prefix(6).enumerated()), id: \.element.model) { index, item in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayModel(item.model))
                                .lineLimit(1)
                            Text(TokenFormat.compact(item.tokens) + " tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(TokenFormat.currency(item.costUSD))
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                    if index < min(models.count, 6) - 1 {
                        Divider().overlay(.white.opacity(0.06))
                    }
                }
            }
        }
        .cardStyle()
        .frame(maxWidth: .infinity)
    }

    private var dataSources: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Data sources")
                .font(.title3.weight(.semibold))
            SourceRow(
                provider: .codex,
                status: "\((snapshot.sourceRecordCounts[.codex] ?? 0).formatted()) records",
                detail: "~/.codex session history"
            )
            Divider().overlay(.white.opacity(0.06))
            SourceRow(
                provider: .claude,
                status: "\((snapshot.sourceRecordCounts[.claude] ?? 0).formatted()) records",
                detail: "~/.claude project history"
            )
            Divider().overlay(.white.opacity(0.06))
            HStack {
                SourceRow(
                    provider: .openRouter,
                    status: openRouterStatus,
                    detail: openRouterDetail
                )
                Spacer()
                if store.openRouterAPIStatus != "API connected" {
                    Button("Connect API") { store.connectOpenRouterAPI() }
                        .buttonStyle(.bordered)
                }
                Menu {
                    if store.openRouterFileName == nil {
                        Button("Add history CSV…") { store.chooseOpenRouterCSV() }
                    } else {
                        Button("Replace history CSV…") { store.chooseOpenRouterCSV() }
                        Button("Remove history CSV", role: .destructive) { store.removeOpenRouterCSV() }
                    }
                    if store.openRouterAPIStatus == "API connected" {
                        Divider()
                        Button("Disconnect API", role: .destructive) {
                            store.disconnectOpenRouterAPI()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            Text(pricingCoverageNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
        .frame(maxWidth: .infinity)
    }

    private var openRouterStatus: String {
        if store.openRouterAPIStatus == "API connected" {
            return "API connected · \(store.openRouterAPIRecordCount.formatted()) records"
        }
        if let fileName = store.openRouterFileName {
            return "\(store.openRouterAPIStatus) · \(fileName)"
        }
        return store.openRouterAPIStatus
    }

    private var openRouterDetail: String {
        if store.openRouterAPIStatus == "API connected" {
            if let fileName = store.openRouterFileName {
                return "Exact 30-day API spend plus older history from \(fileName)"
            }
            return "Exact billed spend from the last 30 completed UTC days"
        }
        if store.openRouterFileName != nil {
            return "Exact billed cost from Activity export"
        }
        return "A management key is required for automatic activity"
    }

    private var pricingCoverageNote: String {
        let base = "Estimates use public API list prices checked 25 Jul 2026. OpenRouter API and export values use exact billed spend."
        guard snapshot.unpricedLabelCount > 0 else { return base }
        return "\(base) \(TokenFormat.compact(snapshot.unpricedTokens)) tokens across \(snapshot.unpricedLabelCount) unpriced label\(snapshot.unpricedLabelCount == 1 ? "" : "s") are excluded from cost."
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("No token history found")
                .font(.title2.weight(.semibold))
            Text("Token Stats reads local Codex and Claude session histories. Use either tool once, then refresh.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Refresh") { store.refresh() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 450)
    }

    private func warning(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Color.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func exportDashboard() {
        let panel = NSSavePanel()
        panel.title = "Export Token Stats"
        panel.nameFieldStringValue = "token-stats-\(Date().formatted(.iso8601.year().month().day())).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let renderer = ImageRenderer(content: ShareCard(
            snapshot: snapshot,
            rangeLabel: dateRangeLabel,
            metric: selectedMetric
        ))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            exportError = "macOS could not render the dashboard."
            return
        }
        do {
            try png.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func rebuildSnapshot(records: [UsageRecord]? = nil) {
        snapshotTask?.cancel()
        let allRecords = records ?? store.records
        let range = selectedRange
        let providers = enabledProviders
        let now = Date()
        isPreparingSnapshot = true
        snapshotTask = Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                DashboardSnapshot.build(
                    allRecords: allRecords,
                    range: range,
                    providers: providers,
                    now: now
                )
            }.value
            guard !Task.isCancelled else { return }
            snapshot = prepared
            isPreparingSnapshot = false
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(color.opacity(0.85))
            }
            Text(value)
                .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderToggle: View {
    let provider: UsageProvider
    let summary: ProviderSummary?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol)
                    .foregroundStyle(provider.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.rawValue)
                        .font(.callout.weight(.semibold))
                    Text("\(TokenFormat.compact(summary?.tokens ?? 0)) · \(TokenFormat.currency(summary?.costUSD ?? 0))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(provider.color.opacity(isEnabled ? 0.11 : 0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(provider.color.opacity(isEnabled ? 0.42 : 0.10), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

private struct SourceRow: View {
    let provider: UsageProvider
    let status: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: provider.symbol)
                .foregroundStyle(provider.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.rawValue).font(.callout.weight(.semibold))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ShareCard: View {
    let snapshot: DashboardSnapshot
    let rangeLabel: String
    let metric: DashboardMetric

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.052, blue: 0.065)
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Token Stats")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text(rangeLabel)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(TokenFormat.compact(snapshot.totalTokens))
                            .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        Text("tokens · \(TokenFormat.currency(snapshot.totalCostUSD)) API equivalent")
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                Chart(snapshot.points) { point in
                    AreaMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value(metric.rawValue, metric == .tokens ? Double(point.tokens) : point.costUSD),
                        series: .value("Provider", point.provider.rawValue)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [point.provider.color.opacity(0.28), point.provider.color.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value(metric.rawValue, metric == .tokens ? Double(point.tokens) : point.costUSD),
                        series: .value("Provider", point.provider.rawValue)
                    )
                    .foregroundStyle(by: .value("Provider", point.provider.rawValue))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale(
                    domain: UsageProvider.allCases.map(\.rawValue),
                    range: UsageProvider.allCases.map(\.color)
                )
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(height: 460)

                HStack(spacing: 16) {
                    ForEach(snapshot.providerSummaries) { summary in
                        HStack(spacing: 14) {
                            Image(systemName: summary.provider.symbol)
                                .font(.title2)
                                .foregroundStyle(summary.provider.color)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.provider.rawValue)
                                    .font(.headline)
                                Text("\(TokenFormat.compact(summary.tokens)) tokens")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Text(TokenFormat.currency(summary.costUSD))
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                HStack {
                    Text("API-equivalent estimates use public list prices checked 25 Jul 2026.")
                    Spacer()
                    Text("Generated by Token Stats")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.36))
            }
            .padding(48)
            .foregroundStyle(.white)
        }
        .frame(width: 1400, height: 900)
        .preferredColorScheme(.dark)
    }
}

private func displayModel(_ model: String) -> String {
    model
        .replacingOccurrences(of: "claude-", with: "Claude ")
        .replacingOccurrences(of: "gpt-", with: "GPT-")
        .replacingOccurrences(of: "-", with: " ")
        .capitalized
        .replacingOccurrences(of: "Gpt", with: "GPT")
}

private extension View {
    func cardStyle() -> some View {
        padding(17)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.white.opacity(0.052))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.white.opacity(0.075), lineWidth: 1)
                    }
            )
    }
}
