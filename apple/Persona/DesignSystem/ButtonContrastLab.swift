#if DEBUG && os(iOS)
import SwiftUI

/// `-showButtonContrast YES` (#6157): a secondary `.themedButton()` on every kind of surface one sits on in the app, for
/// screenshots that measure each label against the button's own fill (`ButtonContrastUITests`).
/// - On the page: the page itself, the grouped page, a card (`Theme.card`), a floating panel (`.surface`) and a
///   settings list's row (`SettingsForm`).
/// - In a sheet, opened with `contrast.openSheet`: the sheet itself, a card in it, a panel in it and a list row in it.
///   The sheet starts at half height and goes to full height with `contrast.expand`.
///
/// Each place has two buttons: one in the accent and one in `Theme.danger`, the two tints call sites give a secondary
/// button. They are drawn over the app in the saved style, color and look (`-ui.style`, `-ui.color`, `-ui.scheme`), and
/// each one's identifier is `contrast.<place>.<accent|danger>`.
struct ButtonContrastOverlay: View {
    @State private var shown = UserDefaults.standard.bool(forKey: "showButtonContrast")
    @State private var sheet = false

    var body: some View {
        if shown {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ButtonContrastRow(place: "page")
                ButtonContrastRow(place: "grouped")
                    .background(Theme.groupedPage, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                ButtonContrastRow(place: "card")
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                ButtonContrastRow(place: "surface")
                    .surface(in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                SettingsForm {
                    Section { ButtonContrastRow(place: "list").themedRow() }
                }
                .themedPage()
                .scrollDisabled(true)
                .scaledFrame(height: Theme.Size.tapTarget * 3)
                Button { sheet = true } label: { Text(verbatim: "sheet") }
                    .accessibilityIdentifier("contrast.openSheet")
                Spacer(minLength: .zero)
            }
            .padding(.horizontal, Theme.Space.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StyleSpec.current.usesGlass ? Color(.systemBackground) : Theme.pageBackground)
            .sheet(isPresented: $sheet) { ButtonContrastSheet() }
        }
    }
}

/// The sheet's places, at half height first.
private struct ButtonContrastSheet: View {
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ButtonContrastRow(place: "sheet")
            ButtonContrastRow(place: "sheetCard")
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            ButtonContrastRow(place: "sheetSurface")
                .surface(in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            SettingsForm {
                Section { ButtonContrastRow(place: "sheetList").themedRow() }
            }
            .themedPage()
            .scrollDisabled(true)
            .scaledFrame(height: Theme.Size.tapTarget * 3)
            Button { detent = detent == .large ? .medium : .large } label: { Text(verbatim: "expand") }
                .accessibilityIdentifier("contrast.expand")
        }
        .padding(Theme.Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.medium, .large], selection: $detent)
        .interactiveDismissDisabled()
    }
}

/// One place: a secondary button in the accent and one in `Theme.danger`, with words of the length real ones have.
private struct ButtonContrastRow: View {
    var place: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button {} label: { Text("Open Settings") }
                .themedButton()
                .accessibilityIdentifier("contrast.\(place).accent")
            Button {} label: { Text("Delete") }
                .themedButton()
                .tint(Theme.danger)
                .accessibilityIdentifier("contrast.\(place).danger")
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
