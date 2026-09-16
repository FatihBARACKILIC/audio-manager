import SwiftUI

/// The `+` / `−` buttons that sit under a list of profiles or schedule rules.
///
/// Both exist because a plain `Image` label does not give two equal buttons: SF Symbols
/// keep their natural width, and `minus` is narrower than `plus`, so the pair comes out
/// visibly mismatched. A fixed square frame on the symbol makes the two the same size,
/// and sharing one view keeps both settings screens matching each other as well.
struct ListActionButton: View {
    let symbol: String
    let label: Text
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
