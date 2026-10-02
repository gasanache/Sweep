import SwiftUI

/// A native selection outline. Categories share one scan; tools own separate workflows.
struct SWPSidebarView: View {
    @EnvironmentObject private var engine: SWPScanEngine

    private var selection: Binding<SWPDestination?> {
        Binding(get: { engine.destination }, set: { if let value = $0 { engine.destination = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wind")
                    .foregroundStyle(SWPTheme.Colors.accent)
                    .accessibilityHidden(true)
                Text("Sweep")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(SWPTheme.Colors.textPrimary)
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 16)

            List(selection: selection) {
                Section {
                    ForEach(SWPCategory.allCases) { category in
                        navigationRow(.cleanup(category))
                    }
                    navigationRow(.localAI)
                } header: {
                    Text("Scan").font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                }
                Section {
                    ForEach(SWPDestination.tools, id: \.self) { destination in
                        navigationRow(destination)
                    }
                } header: {
                    Text("Tools").font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("navigation")

            if engine.lastScanDate != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Last cleanup scan")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                    Text("\(SWPBytes.string(engine.result.totalBytes)) in findings")
                        .font(SWPTheme.Fonts.rowTitle.monospacedDigit())
                        .foregroundStyle(SWPTheme.Colors.textPrimary)
                    Text("Allocated size, not freed space")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
                .padding(16)
            }
        }
        .background(SWPTheme.Colors.surface)
    }

    private func navigationRow(_ destination: SWPDestination) -> some View {
        let selected = engine.destination == destination
        let title = Text(destination.title)
            .font(selected ? SWPTheme.Fonts.rowTitle : SWPTheme.Fonts.list)
            .lineLimit(1)
        let size: String?
        if case .cleanup(let category) = destination,
           engine.lastScanDate != nil, engine.result.bytes(in: category) > 0 {
            size = SWPBytes.string(engine.result.bytes(in: category))
        } else {
            size = nil
        }
        return HStack(spacing: 9) {
            Image(systemName: destination.symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(selected ? SWPTheme.Colors.accent : SWPTheme.Colors.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            if let size {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        Text(size).font(SWPTheme.Fonts.caption.monospacedDigit())
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                            .fixedSize()
                    }
                    title.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                title.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(SWPTheme.Colors.textPrimary)
        .frame(minHeight: 24)
        .padding(.vertical, 1)
        .background(SWPNeutralListSelection())
        .tag(destination)
        .listRowSeparator(.hidden)
        .listRowBackground(selected ? SWPTheme.Colors.surfaceHigh : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(destination.title)
        .accessibilityValue(size.map { "\($0) allocated in last scan" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("navigation." + destination.id)
        .help(destination.isCleanup && engine.lastScanDate == nil
              ? "One scan checks cleanup categories and AI locations. Review this category after scanning."
              : destination.title + (size.map { " · \($0) allocated in last scan" } ?? ""))
    }
}
