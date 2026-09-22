import SwiftUI

/// VLC's "Open Network Stream" (⌘⇧O) — play a direct URL instead of a local file.
struct OpenNetworkStreamView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Network Stream")
                .font(.headline)

            Text("Enter a direct video or audio URL.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("https://example.com/video.mp4", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(open)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFieldFocused = true }
    }

    private func open() {
        guard !urlString.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.playNetworkStream(urlString: urlString)
        dismiss()
    }
}
