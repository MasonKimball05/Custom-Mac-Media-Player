import SwiftUI

/// Browse and search the desktop's media library (shelf) and play from it.
struct LibrarySidebarView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var showingHomeScreen: Bool

    private enum LoadState: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    @State private var roots: [String] = []
    @State private var root = ""
    @State private var path: [String] = []        // folder stack under the root
    @State private var listing: ShelfListing?
    @State private var searchText = ""
    @State private var searchResults: [ShelfFile] = []
    @State private var state: LoadState = .idle
    @State private var selection: String?

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await loadRoots() }
        .task(id: searchText) { await runSearch() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if roots.count > 1 {
                    Picker("Library", selection: $root) {
                        ForEach(roots, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: root) { _, _ in
                        path = []
                        Task { await browse() }
                    }
                } else {
                    Text(root.isEmpty ? "Library" : root).font(.headline)
                }
                Spacer()
                Button {
                    Task { roots.isEmpty ? await loadRoots() : await browse() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if !path.isEmpty && !isSearching {
                HStack(spacing: 4) {
                    Button {
                        path.removeLast()
                        Task { await browse() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Text(path.joined(separator: " \u{203A} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            TextField("Search library", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(roots.isEmpty)
        }
        .padding(10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .failed(let message):
            unavailable(message)
        case .loading where listing == nil && searchResults.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            List(selection: $selection) {
                if isSearching {
                    if searchResults.isEmpty && state == .ready {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                    ForEach(searchResults) { fileRow($0, showPath: true) }
                } else if let listing {
                    ForEach(listing.dirs, id: \.self) { dir in
                        Label(dir, systemImage: "folder")
                            .tag("dir:" + dir)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(dir) }
                            .contextMenu { Button("Open") { open(dir) } }
                    }
                    ForEach(listing.files) { fileRow($0, showPath: false) }
                    if listing.dirs.isEmpty && listing.files.isEmpty {
                        Text("This folder is empty").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func fileRow(_ file: ShelfFile, showPath: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(file.name, systemImage: file.isVideo ? "film" : "music.note")
                .lineLimit(1)
            Text(showPath ? "\(file.root)/\(file.path)" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .tag("file:" + file.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(file) }
        .contextMenu {
            Button("Play") { play(file) }
            Button("Add to Playlist") { viewModel.enqueueLibraryFiles([file]) }
        }
        .help(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: ShelfClient.shared.isConfigured ? "desktopcomputer.trianglebadge.exclamationmark" : "externaldrive.connected.to.line.below")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if ShelfClient.shared.isConfigured {
                Button("Try Again") { Task { await loadRoots() } }
            } else {
                SettingsLink { Text("Open Settings") }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func play(_ file: ShelfFile) {
        viewModel.playLibraryFile(file)
        showingHomeScreen = false
    }

    private func open(_ dir: String) {
        path.append(dir)
        Task { await browse() }
    }

    private func loadRoots() async {
        state = .loading
        do {
            let r = try await ShelfClient.shared.roots()
            roots = r.roots
            if !roots.contains(root) { root = roots.first ?? "" }
            await browse()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func browse() async {
        guard !root.isEmpty else { return }
        state = .loading
        do {
            listing = try await ShelfClient.shared.browse(root: root, path: path.joined(separator: "/"))
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func runSearch() async {
        guard isSearching else {
            searchResults = []
            return
        }
        // .task(id:) cancels the previous search on each keystroke, so this
        // short pause debounces typing before hitting the server.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            searchResults = try await ShelfClient.shared.search(searchText)
            state = .ready
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
