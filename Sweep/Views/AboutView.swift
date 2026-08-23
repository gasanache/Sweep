import SwiftUI
import AppKit

// MARK: - About

/// Custom About window, replacing the stock grey panel.
///
/// About is where someone who has just watched a cleaner ask for their
/// administrator password goes to decide how they feel about that. So this is
/// not a splash screen: it states the three promises the app is built on, and
/// then gives the practical things a person actually comes here for — what
/// exactly is installed, what it is running on, and a way to copy that into a
/// bug report without retyping it.
struct SWPAboutView: View {

    @State private var didCopy = false

    // MARK: Facts

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
            + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// What this copy of the binary is running as, not what it contains — a
    /// universal build reports the slice actually in use.
    private var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }

    private var versionReport: String {
        """
        Sweep \(shortVersion) (\(build))
        \(systemVersion) · \(architecture)
        """
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            identity

            promises
                .padding(.horizontal, 22)
                .padding(.top, 20)

            systemCard
                .padding(.horizontal, 22)
                .padding(.top, 10)

            footer
                .padding(.top, 18)
                .padding(.bottom, 20)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(SWPTheme.Colors.background)
        // No `.preferredColorScheme` anywhere in the app: appearance is driven
        // by `NSApp.appearance` plus each window's own override, because a
        // per-window override set by SwiftUI outranks the application one and
        // left "System" unable to take effect. Hard-coding dark here had also
        // made this the one window that ignored the setting entirely.
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: SWPTheme.Colors.accent.opacity(0.22), radius: 20, y: 5)
                .padding(.top, 30)
                .accessibilityHidden(true)

            Text("Sweep")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(SWPTheme.Colors.textPrimary)
                .padding(.top, 12)

            Text("Cleans what apps leave behind")
                .font(SWPTheme.Fonts.body)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .padding(.top, 3)
        }
    }

    // MARK: Promises

    private var promises: some View {
        VStack(alignment: .leading, spacing: 0) {
            promise(symbol: "trash",
                    title: "Never deletes",
                    detail: "Everything goes to the Trash. Put Back always works.")
            SWPHairline().opacity(0.6)
            promise(symbol: "checkmark.square",
                    title: "Never chooses for you",
                    detail: "A scan ends with nothing ticked. Every removal is yours.")
            SWPHairline().opacity(0.6)
            promise(symbol: "network.slash",
                    title: "Never goes online",
                    detail: "No telemetry, no analytics, no update checks. Apple frameworks only.")
        }
        .swpCard()
    }

    private func promise(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SWPTheme.Colors.accent)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SWPTheme.Fonts.rowTitle)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text(detail)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    // MARK: System

    /// Version and host details, with one click to copy them.
    ///
    /// Every bug report needs exactly these three facts, and asking someone to
    /// transcribe a build number from a screenshot is how reports arrive
    /// missing it.
    private var systemCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shortVersion) (\(build))")
                    .font(SWPTheme.Fonts.rowTitle.monospacedDigit())
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text("\(systemVersion) · \(architecture)")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(versionReport, forType: .string)
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(SWPTheme.Fonts.caption)
            }
            .buttonStyle(SWPSecondaryButtonStyle())
            .help("Copy version and system details for a bug report")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .swpCard()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Link(destination: URL(string: "https://github.com/gasanache/Sweep")!) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("github.com/gasanache/Sweep")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(SWPTheme.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Text("GPL-3.0 · © 2026 George Asanache")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
        }
    }
}
