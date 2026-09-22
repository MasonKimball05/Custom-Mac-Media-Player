import SwiftUI

/// Small name-entry sheet, reused for both "Save Playlist As…" and "Rename Playlist".
struct SavePlaylistNameView: View {
    var title: String = "Save Playlist As"
    var initialName: String = ""
    var confirmTitle: String = "Save"
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            name = initialName
            isFieldFocused = true
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
