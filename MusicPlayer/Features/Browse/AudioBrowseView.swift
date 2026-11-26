import MusicCore
import SwiftUI

struct AudioBrowseView: View {
    let environment: AppEnvironment
    @Bindable var model: AudioBrowseViewModel
    let onImported: (ImportJob) -> Void

    var body: some View {
        Group {
            if model.isLoading && model.audios.isEmpty {
                ProgressView("Loading audio…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.audios.isEmpty {
                emptyState
            } else {
                audioList
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.audios.isEmpty {
                selectionBar
            }
        }
        .navigationTitle(model.chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .musicBarBackground()
        .refreshable { await model.reload() }
        .task { await model.loadFirstPage() }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.importErrorMessage {
                StatusBanner(kind: .error, message: errorMessage)
                    .padding()
            }
        }
    }

    private var audioList: some View {
        List {
            ForEach(model.audios) { audio in
                Button {
                    model.toggle(audio)
                } label: {
                    AudioRowView(
                        audio: audio,
                        isSelected: model.isSelected(audio),
                        isImported: model.isImported(audio)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browse.row.\(audio.messageID)")
                .task { await model.loadMoreIfNeeded(current: audio) }
            }

            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No audio here", systemImage: "waveform.slash")
        } description: {
            Text("This chat has no audio files that can be imported. Try another chat.")
        } actions: {
            if let errorMessage = model.errorMessage {
                Button("Try again") {
                    Task { await model.reload() }
                }
                .accessibilityHint(errorMessage)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.count(model.selectionCount, singular: "song selected", plural: "songs selected"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("browse.selectionCount")
                Text(model.isSelectionEmpty ? "Tap songs to select them" : "Ready for one resumable batch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !model.isSelectionEmpty {
                Button("Select all") { model.selectAllLoaded() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
            }

            Button {
                Task {
                    if let job = await model.importSelection() {
                        onImported(job)
                    }
                }
            } label: {
                if model.isImporting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label("Import", systemImage: "arrow.down.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSelectionEmpty || model.isImporting)
            .accessibilityLabel("Import selected songs")
            .accessibilityIdentifier("browse.import")
        }
        .padding(14)
        .glassCard(prominent: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
