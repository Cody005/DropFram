import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    DropFrameHeader(
                        eyebrow: "Local transfer desk",
                        title: "Download queue",
                        trailingSymbol: "arrow.clockwise",
                        action: {}
                    )

                    if model.jobs.isEmpty {
                        QueueEmptyState()
                    } else {
                        ForEach(model.jobs) { job in
                            DownloadJobCard(job: job)
                        }
                    }

                    QueueFootnote()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(DropFramePalette.downloadsCanvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct QueueEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 43, weight: .black))
                Spacer()
                Text("00")
                    .font(.system(size: 50, weight: .black, design: .monospaced))
                    .opacity(0.15)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("The runway is clear.")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                Text("Paste a link on Grab, pick a quality, and the transfer will appear here.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DropFramePalette.ink.opacity(0.62))
            }
        }
        .foregroundStyle(DropFramePalette.ink)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DropFramePalette.signal, in: .rect(cornerRadius: 18))
    }
}

private struct DownloadJobCard: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 13) {
                statusIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.mediaTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    EditorialLabel(text: "\(job.formatLabel) · \(statusText)")
                }
                Spacer()
            }

            switch job.phase {
            case .downloading, .queued:
                if let progress = job.progress {
                    ProgressView(value: progress)
                        .tint(DropFramePalette.cobalt)
                } else {
                    ProgressView()
                        .tint(DropFramePalette.cobalt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .finished:
                Capsule()
                    .fill(DropFramePalette.mint)
                    .frame(height: 6)
            case .failed:
                Capsule()
                    .fill(DropFramePalette.coral)
                    .frame(height: 6)
            }
        }
        .padding(16)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(DropFramePalette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.phase {
        case .queued:
            Image(systemName: "clock.fill")
                .foregroundStyle(DropFramePalette.violet)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .symbolEffect(.pulse)
                .foregroundStyle(DropFramePalette.cobalt)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DropFramePalette.mint)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DropFramePalette.coral)
        }
    }

    private var statusText: String {
        switch job.phase {
        case .queued: "Waiting"
        case .downloading:
            if let progress = job.progress {
                "Downloading \(Int(progress * 100))%"
            } else if job.receivedBytes > 0 {
                "Downloading \(receivedBytesText)"
            } else if job.isAdaptive {
                "Downloading stream…"
            } else {
                "Connecting…"
            }
        case .finished: "Saved"
        case .failed(let message): message
        }
    }

    private var receivedBytesText: String {
        ByteCountFormatter.string(
            fromByteCount: job.receivedBytes,
            countStyle: .file
        )
    }
}

private struct QueueFootnote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DropFramePalette.cobalt)
            Text("DropFrame automatically saves direct video files and adaptive streams in the offline format supported by iPhone.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DropFramePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(DropFramePalette.cobalt.opacity(0.08), in: .rect(cornerRadius: 15))
    }
}
