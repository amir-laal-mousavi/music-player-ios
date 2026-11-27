import MusicCore
import MusicLibrary
import XCTest
@testable import MusicBit

@MainActor
final class AudioBrowseViewModelTests: XCTestCase {
    private func makeModel(
        audios: [TelegramAudio],
        chat: TelegramChat
    ) async throws -> (AudioBrowseViewModel, InMemoryLibraryStore) {
        let gateway = FakeTelegramGateway(chats: [chat], audios: audios)
        let store = InMemoryLibraryStore()
        let coordinator = ImportCoordinator(
            gateway: gateway,
            store: store,
            fileStore: try makeFileStore()
        )
        let model = AudioBrowseViewModel(
            chat: chat,
            gateway: gateway,
            store: store,
            coordinator: coordinator
        )
        await model.loadFirstPage()
        return (model, store)
    }

    func testToggleSelectsAndDeselectsSongs() async throws {
        let chat = try makeChat()
        let audios = [try makeAudio(messageID: 103), try makeAudio(messageID: 102)]
        let (model, _) = try await makeModel(audios: audios, chat: chat)

        XCTAssertEqual(model.audios.map(\.messageID), [103, 102])
        XCTAssertTrue(model.isSelectionEmpty)

        model.toggle(audios[0])
        XCTAssertTrue(model.isSelected(audios[0]))
        XCTAssertEqual(model.selectionCount, 1)
        XCTAssertEqual(model.selectedAudios.map(\.messageID), [103])

        model.toggle(audios[0])
        XCTAssertFalse(model.isSelected(audios[0]))
        XCTAssertTrue(model.isSelectionEmpty)
    }

    func testSelectAllLoadedAndClearSelection() async throws {
        let chat = try makeChat()
        let audios = [try makeAudio(messageID: 103), try makeAudio(messageID: 102)]
        let (model, _) = try await makeModel(audios: audios, chat: chat)

        model.selectAllLoaded()
        XCTAssertEqual(model.selectionCount, 2)

        model.clearSelection()
        XCTAssertEqual(model.selectionCount, 0)
    }

    func testSongsAlreadyInLibraryAreMarkedImported() async throws {
        let chat = try makeChat()
        let audios = [try makeAudio(messageID: 103), try makeAudio(messageID: 102)]
        let gateway = FakeTelegramGateway(chats: [chat], audios: audios)
        let existing = try makeTrack(audio: audios[1], chat: chat)
        let store = InMemoryLibraryStore(tracks: [existing])
        let coordinator = ImportCoordinator(
            gateway: gateway,
            store: store,
            fileStore: try makeFileStore()
        )
        let model = AudioBrowseViewModel(chat: chat, gateway: gateway, store: store, coordinator: coordinator)

        await model.loadFirstPage()

        XCTAssertTrue(model.isImported(audios[1]))
        XCTAssertFalse(model.isImported(audios[0]))
    }

    func testImportSelectionEnqueuesOneJobAndClearsSelection() async throws {
        let chat = try makeChat()
        let audios = [try makeAudio(messageID: 103), try makeAudio(messageID: 102)]
        let (model, store) = try await makeModel(audios: audios, chat: chat)

        model.selectAllLoaded()
        let job = await model.importSelection()

        let unwrapped = try XCTUnwrap(job)
        XCTAssertEqual(unwrapped.items.count, 2)
        XCTAssertEqual(unwrapped.chatID, chat.id)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.importErrorMessage)

        let saved = try await store.importJobs()
        XCTAssertEqual(saved.count, 1)
    }

    func testImportSelectionRequiresASelection() async throws {
        let chat = try makeChat()
        let (model, _) = try await makeModel(audios: [try makeAudio(messageID: 103)], chat: chat)

        let job = await model.importSelection()
        XCTAssertNil(job)
    }
}
