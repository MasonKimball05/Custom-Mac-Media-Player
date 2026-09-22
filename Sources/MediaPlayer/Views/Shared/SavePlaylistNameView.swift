import SwiftUI

/// Small name-entry sheet for "Save Playlist As…" — same shape as OpenNetworkStreamView.
struct SavePlaylistNameView: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Playlist As")
                .font(.headline)

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isFieldFocused = true }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
