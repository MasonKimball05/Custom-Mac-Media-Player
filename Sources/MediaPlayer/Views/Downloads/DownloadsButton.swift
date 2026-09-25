import AppKit
import SwiftUI

/// Toolbar button for yt-dlp downloads: a progress ring while something is downloading,
/// and a popover listing downloads with their progress and what to do with the results.
/// Only shown once there's been a download this session.
struct DownloadsButton: View {
    @ObservedObject var downloads: DownloadManager
    let onPlay: (URL) -> Void

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            if let fraction = downloads.overallFraction {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .help("Downloads")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            DownloadsList(downloads: downloads) { url in
                showingPopover = false
                onPlay(url)
            }
        }
    }
}

private struct DownloadsList: View {
    @ObservedObject var downloads: DownloadManager
    let onPlay: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("New\u{2026}") {
                    NotificationCenter.default.post(name: .downloadFromURL, object: nil)
                }
            }
            .padding(12)

            YTDLPUpdateNotice(updates: downloads.updates)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job, downloads: downloads, onPlay: onPlay)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            if downloads.jobs.contains(where: { !$0.isRunning }) {
                HStack {
                    Spacer()
                    Button("Clear Finished") { downloads.clearFinished() }
                        .buttonStyle(.link)
                }
                .padding(10)
            }
        }
        .frame(width: 380)
    }
}

private struct DownloadRow: View {
    let job: DownloadManager.Job
    @ObservedObject var downloads: DownloadManager
    let onPlay: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: job.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }

            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .running:
            if let fraction = job.fraction {
                ProgressView(value: fraction) {
                    Text("\(job.stage) \u{2013} \(Int((fraction * 100).rounded()))%")
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
                .font(.caption)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(job.stage)\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .finished(_, let files):
            Text(files.count == 1 ? "Downloaded" : "Downloaded \(files.count) files")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption).foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .running:
            iconButton("xmark.circle.fill", help: "Cancel Download") { downloads.cancel(job.id) }
        case .finished(let mediaFile, let files):
            if let mediaFile {
                iconButton("play.circle.fill", help: "Play") { onPlay(mediaFile) }
            }
            iconButton("magnifyingglass.circle.fill", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        case .failed, .cancelled:
            iconButton("xmark.circle", help: "Remove from List") { downloads.remove(job.id) }
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
