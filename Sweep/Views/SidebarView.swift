import SwiftUI

// MARK: - Sidebar

/// Category rail. Doubles as the scan summary: each row carries its own byte
/// count, so the split of what was found is legible without clicking through
/// all five categories.
struct SWPSidebarView: View {

    @EnvironmentObject private var engine: SWPScanEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 3) {
                ForEach(SWPCategory.allCases) { category in
                    row(for: category)
                }
            }
            .padding(.horizontal, 10)

            SWPHairline()
                .opacity(0.6)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

            uninstallerRow
                .padding(.horizontal, 10)

            Spacer(minLength: SWPTheme.Spacing.section)

            if engine.hasResults {
                totalPanel
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SWPTheme.Colors.surface)
    }

    // MARK: Header

    private var header: some View {
        // Leaves room for the traffic lights, which float over the content in a
        // hidden-title-bar window.
        HStack(spacing: 8) {
            SWPIconTile(symbol: "wind", size: 22)
            Text("Sweep")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(SWPTheme.Colors.textPrimary)
        }
        .padding(.leading, 14)
        .padding(.top, 38)
        .padding(.bottom, SWPTheme.Spacing.section)
    }

    // MARK: Rows

    private func row(for category: SWPCategory) -> some View {
        let isSelected = engine.selectedCategory == category && !engine.isUninstallerActive
        let bytes = engine.result.bytes(in: category)
        let count = engine.result.groups(in: category).count

        return Button {
            engine.isUninstallerActive = false
            engine.selectedCategory = category
        } label: {
            HStack(spacing: 9) {
                SWPIconTile(symbol: category.symbolName,
                            tint: isSelected ? SWPTheme.Colors.accent : SWPTheme.Colors.textDim,
                            size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(SWPTheme.Fonts.rowTitle)
                        .foregroundStyle(isSelected
                                         ? SWPTheme.Colors.textPrimary
                                         : SWPTheme.Colors.textSecondary)
                    if count > 0 {
                        Text(SWPBytes.string(bytes))
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                    }
                }

                Spacer(minLength: 4)

                if count > 0 {
                    Text("\(count)")
                        .font(SWPTheme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusRow, style: .continuous)
                    .fill(isSelected ? SWPTheme.Colors.surfaceHigh : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Uninstaller

    private var uninstallerRow: some View {
        let isSelected = engine.isUninstallerActive
        return Button {
            engine.isUninstallerActive = true
        } label: {
            HStack(spacing: 9) {
                SWPIconTile(symbol: "app.dashed",
                            tint: isSelected ? SWPTheme.Colors.accent : SWPTheme.Colors.textDim,
                            size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uninstaller")
                        .font(SWPTheme.Fonts.rowTitle)
                        .foregroundStyle(isSelected
                                         ? SWPTheme.Colors.textPrimary
                                         : SWPTheme.Colors.textSecondary)
                    Text("App + its files")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusRow, style: .continuous)
                    .fill(isSelected ? SWPTheme.Colors.surfaceHigh : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Total

    private var totalPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FOUND")
                .font(SWPTheme.Fonts.badge)
                .tracking(0.8)
                .foregroundStyle(SWPTheme.Colors.textDim)

            let bytes = SWPBytes.split(engine.result.totalBytes)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(bytes.value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text(bytes.unit)
                    .font(SWPTheme.Fonts.heroUnit)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }

            Text("across \(engine.result.appsInventoried) installed apps")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .swpCard(elevated: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
}
