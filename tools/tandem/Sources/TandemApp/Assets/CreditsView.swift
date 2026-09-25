import AppKit
import SwiftUI
import TandemAssets

/// The credits the project's assets need in the video description, what to
/// sort out before publishing, and a button to copy the block.
struct CreditsView: View {
    let model: EditorModel
    @State private var includeThanks = false

    var body: some View {
        let result = AssetLibraryHost.shared.credits(for: model)
        VStack(alignment: .leading, spacing: 12) {
            Text("Credits")
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
            switch result {
            case .failure(let error):
                Text(AssetLibraryHost.describe(error))
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            case .success(let credits):
                let text = credits.text(includeOptional: includeThanks)
                if credits.assets.isEmpty {
                    Text("This project doesn't use anything from the asset library yet.")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text.isEmpty ? "Nothing here needs a credit." : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Theme.textMuted.color : Theme.text.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
                    ForEach(credits.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Theme.amber.color).frame(width: 5, height: 5).padding(.top, 5)
                            Text(warning)
                                .font(.ui(11))
                                .foregroundStyle(Theme.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(credits.assets, id: \.id) { used in
                            HStack(spacing: 6) {
                                Text(used.name).font(.ui(11)).foregroundStyle(Theme.textSecondary.color).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(AssetBrowsing.licenceLabel(used.licenceClass)).font(.ui(10.5)).foregroundStyle(Theme.textFaint.color)
                            }
                        }
                    }
                    HStack {
                        Toggle("Thank sources that don't ask for it", isOn: $includeThanks)
                            .toggleStyle(.checkbox)
                            .font(.ui(11))
                            .foregroundStyle(Theme.textMuted.color)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            model.show(.info, "Copied the credits for the description.")
                        }
                        .disabled(text.isEmpty)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.raised.color)
    }
}
