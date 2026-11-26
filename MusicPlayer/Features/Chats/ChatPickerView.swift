import MusicCore
import MusicLibrary
import SwiftUI

struct ChatPickerView: View {
    let environment: AppEnvironment
    @Bindable var model: ChatPickerViewModel
    let account: TelegramAccount?
    let onSignOut: () -> Void

    @State private var importModel: ImportProgressViewModel?

    var body: some View {
        List {
            if let account {
                Section {
                    accountRow(account)
                }
            }

            Section {
                if model.isLoading && model.chats.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading chats…")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if model.filteredChats.isEmpty {
                    emptyChats
                } else {
                    ForEach(model.filteredChats) { chat in
                        NavigationLink {
                            AudioBrowseView(
                                environment: environment,
                                chat: chat,
                                onImported: { job in
                                    importModel = ImportProgressViewModel(
                                        store: environment.store,
                                        coordinator: environment.coordinator,
                                        jobID: job.id
                                    )
                                }
                            )
                        } label: {
                            ChatRow(chat: chat)
                        }
                        .accessibilityIdentifier("chat.row.\(chat.id)")
                    }
                }
            } header: {
                SectionHeading(
                    title: "Choose a chat",
                    subtitle: "Songs already in your library are skipped automatically"
                )
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.query, prompt: "Search chats")
        .refreshable { await model.reload() }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .warning, message: errorMessage)
                    .padding()
            }
        }
        .task { await model.load() }
        .sheet(isPresented: isShowingImport) {
            if let importModel {
                ImportProgressView(model: importModel)
            }
        }
    }

    private var emptyChats: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isSearching ? "No chats match “\(model.query)”." : "No chats available")
                .font(.subheadline.weight(.semibold))
            Text("Open a conversation in Telegram, then pull down to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func accountRow(_ account: TelegramAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body.weight(.semibold))
                Text(account.maskedPhoneNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Sign out", role: .destructive, action: onSignOut)
                .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.row")
    }

    private var isShowingImport: Binding<Bool> {
        Binding(
            get: { importModel != nil },
            set: { isPresented in
                if !isPresented { importModel = nil }
            }
        )
    }
}

struct ChatRow: View {
    let chat: TelegramChat

    private var symbol: String {
        switch chat.kind {
        case .user: return "person.fill"
        case .group: return "person.2.fill"
        case .channel: return "megaphone.fill"
        }
    }

    private var kindLabel: String {
        switch chat.kind {
        case .user: return "Direct chat"
        case .group: return "Group"
        case .channel: return "Channel"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(
                    Theme.card,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.title), \(kindLabel)")
    }
}
