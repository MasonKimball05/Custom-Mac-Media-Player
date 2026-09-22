import SwiftUI
import UniformTypeIdentifiers

/// Playlist list. Reorderable, removable, shows what's currently playing with
/// a live equalizer glyph rather than just a highlighted row.
struct PlaylistSidebarView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onOpenFile: () -> Void

    @State private var showingClearConfirmation = false
    @State private var showingSaveAsSheet = false
    @State private var selection = Set<MediaItem.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Section("Saved Playlists") {
                        if viewModel.savedPlaylists.isEmpty {
                            Text("No saved playlists yet")
                        }
                        ForEach(viewModel.savedPlaylists) { saved in
                            Button {
                                viewModel.loadSavedPlaylist(id: saved.id)
                            } label: {
                                if saved.id == viewModel.activeSavedPlaylistID {
                                    Label(saved.name, systemImage: "checkmark")
                                } else {
                                    Text(saved.name)
                                }
                            }
                        }
                    }

                    Divider()

                    Button("New Playlist") {
                        viewModel.startNewPlaylist()
                    }
                    Button("Save Playlist As\u{2026}") {
                        showingSaveAsSheet = true
                    }
                    .disabled(viewModel.playlist.isEmpty)

                    if let activeID = viewModel.activeSavedPlaylistID,
                       let active = viewModel.savedPlaylists.first(where: { $0.id == activeID }) {
                        Button("Delete \u{201C}\(active.name)\u{201D}", role: .destructive) {
                            viewModel.deleteSavedPlaylist(id: activeID)
                        }
                    }

                    Divider()

                    Button("Export to M3U\u{2026}") {
                        exportPlaylist()
                    }
                    .disabled(viewModel.playlist.isEmpty)
                    Button("Import M3U\u{2026}") {
                        importPlaylist()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(viewModel.activePlaylistDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Button {
                    if selection.count == viewModel.playlist.count {
                        selection.removeAll()
                    } else {
                        selection = Set(viewModel.playlist.map(\.id))
                    }
                } label: {
                    Image(systemName: isAllSelected ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isAllSelected ? "Deselect All" : "Select All")
                .disabled(viewModel.playlist.isEmpty)

                Button {
                    if selection.isEmpty {
                        showingClearConfirmation = true
                    } else {
                        viewModel.removeItems(selection)
                        selection.removeAll()
                    }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(selection.isEmpty ? "Clear Playlist" : "Remove \(selection.count) Selected")
                .disabled(viewModel.playlist.isEmpty)
                .confirmationDialog(
                    "Clear the playlist?",
                    isPresented: $showingClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Playlist", role: .destructive) {
                        viewModel.clearPlaylist()
                    }
                } message: {
                    Text("This removes every item from the playlist and stops playback. It doesn't delete the actual files.")
                }

                Button(action: onOpenFile) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add files\u{2026}")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.playlist.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "music.note.list")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No items yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // `selection:` is what makes single-click actually do something (select,
                // with the usual Cmd-click-to-toggle / Shift-click-to-extend-range), and
                // it's also what makes multi-item drag reordering work for free — dragging
                // any selected row moves the whole selected block together.
                List(selection: $selection) {
                    ForEach(viewModel.playlist) { item in
                        PlaylistRow(
                            item: item,
                            isCurrent: item.id == viewModel.currentItemID,
                            isPlaying: viewModel.isPlaying && item.id == viewModel.currentItemID
                        )
                        .tag(item.id)
                    }
                    .onMove { source, destination in
                        viewModel.moveItems(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: MediaItem.ID.self) { selectedIDs in
                    if selectedIDs.count > 1 {
                        Button("Remove \(selectedIDs.count) Items", role: .destructive) {
                            viewModel.removeItems(selectedIDs)
                            selection.subtract(selectedIDs)
                        }
                    } else if let id = selectedIDs.first, let item = viewModel.playlist.first(where: { $0.id == id }) {
                        Button("Play") { viewModel.play(item: item) }
                        Button("Remove", role: .destructive) {
                            viewModel.removeItems(selectedIDs)
                            selection.subtract(selectedIDs)
                        }
                    }
                } primaryAction: { selectedIDs in
                    guard let id = selectedIDs.first, let item = viewModel.playlist.first(where: { $0.id == id }) else { return }
                    viewModel.play(item: item)
                }
                .onDeleteCommand {
                    viewModel.removeItems(selection)
                    selection.removeAll()
                }
            }
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingSaveAsSheet) {
            SavePlaylistNameView { name in
                viewModel.saveCurrentPlaylist(as: name)
            }
        }
    }

    private var isAllSelected: Bool {
        !viewModel.playlist.isEmpty && selection.count == viewModel.playlist.count
    }

    private func exportPlaylist() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8")].compactMap { $0 }
        panel.nameFieldStringValue = "\(viewModel.activePlaylistDisplayName).m3u8"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.exportPlaylist(to: url)
        }
    }

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["m3u8", "m3u"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.importPlaylist(from: url)
        }
    }
}

private struct PlaylistRow: View {
    let item: MediaItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                    .frame(width: 28, height: 28)
                if isPlaying {
                    EqualizerGlyph()
                } else {
                    Image(systemName: item.isVideo ? "film" : "music.note")
                        .font(.system(size: 12))
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                if let duration = item.duration {
                    Text(TimeFormatter.string(from: duration))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// Tiny animated bars, the classic "now playing" indicator.
private struct EqualizerGlyph: View {
    @State private var animate = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: animate ? CGFloat.random(in: 5...14) : 5)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12),
                        value: animate
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animate = true }
    }
}
