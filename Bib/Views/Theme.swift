import SwiftUI

enum BibTheme {
    static let accent = Color(red: 0.43, green: 0.36, blue: 0.68)
    static let softAccent = accent.opacity(0.09)

    static var canvas: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var readerBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

struct QuietPlaceholder<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(BibTheme.accent)
                .frame(width: 76, height: 76)
                .background(BibTheme.softAccent, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(.title2, design: .serif))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 310)
            }
            actions()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
