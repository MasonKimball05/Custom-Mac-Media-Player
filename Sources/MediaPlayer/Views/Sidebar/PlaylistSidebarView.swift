import SwiftUI
import UniformTypeIdentifiers

/// Playlist list. Reorderable, removable, shows what's currently playing with
/// a live equalizer glyph rather than just a highlighted row.
struct PlaylistSidebarView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onOpenFile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
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
                List {
                    ForEach(viewModel.playlist) { item in
                        PlaylistRow(
                            item: item,
                            isCurrent: item.id == viewModel.currentItemID,
                            isPlaying: viewModel.isPlaying && item.id == viewModel.currentItemID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            viewModel.play(item: item)
                        }
                        .contextMenu {
                            Button("Play") { viewModel.play(item: item) }
                            Button("Remove", role: .destructive) { viewModel.removeItem(item) }
                        }
                    }
                    .onMove { source, destination in
                        viewModel.moveItems(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 220, idealWidth: 240)
        .background(.ultraThinMaterial)
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
