import MusicCore
import MusicLibrary
import XCTest
@testable import MusicPlayer

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private func makeModel(tracks: [Track]) async throws -> LibraryViewModel {
        let store = InMemoryLibraryStore(tracks: tracks)
        let coordinator = ImportCoordinator(
            gateway: FakeTelegramGateway(),
            store: store,
            fileStore: try makeFileStore()
        )
        let model = LibraryViewModel(store: store, coordinator: coordinator, player: FakePlayerEngine())
        await model.start()
        return model
    }

    func testStartPublishesStoredTracksNewestFirst() async throws {
        let chat = try makeChat()
        let older = try makeTrack(
            audio: try makeAudio(messageID: 101, title: "Older"),
            chat: chat,
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = try makeTrack(
            audio: try makeAudio(messageID: 102, title: "Newer"),
            chat: chat,
            importedAt: Date(timeIntervalSince1970: 200)
        )

        let model = try await makeModel(tracks: [older, newer])

        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.tracks.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(model.totalDuration, 4, accuracy: 0.001)
    }

    func testFilterMatchesTitleArtistAndSourceChat() async throws {
        let focus = try makeChat(id: 1001, title: "Focus")
        let drive = try makeChat(id: 1002, title: "Sunset Drive", kind: .channel)
        let night = try makeTrack(
            audio: try makeAudio(messageID: 103, title: "Night Drive", performer: "Aurora"),
            chat: focus
        )
        let tide = try makeTrack(
            audio: try makeAudio(chatID: 1002, messageID: 201, title: "Slow Tide", performer: "Harbour"),
            chat: drive
        )
        let model = try await makeModel(tracks: [night, tide])

        model.query = "aurora"
        XCTAssertEqual(model.filteredTracks.map(\.title), ["Night Drive"])

        model.query = "sunset"
        XCTAssertEqual(model.filteredTracks.map(\.title), ["Slow Tide"])

        model.query = "   "
        XCTAssertEqual(model.filteredTracks.count, 2)
    }

    func testPlaybackRequestUsesFilteredOrder() async throws {
        let chat = try makeChat()
        let first = try makeTrack(
            audio: try makeAudio(messageID: 103, title: "Alpha"),
            chat: chat,
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let second = try makeTrack(
            audio: try makeAudio(messageID: 102, title: "Beta"),
            chat: chat,
            importedAt: Date(timeIntervalSince1970: 200)
        )
        let model = try await makeModel(tracks: [first, second])

        let request = try XCTUnwrap(model.playbackRequest(for: first))
        XCTAssertEqual(request.tracks.map(\.title), ["Beta", "Alpha"])
        XCTAssertEqual(request.startingIndex, 1)
    }

    func testEmptyLibraryIsReportedOnlyAfterLoading() async throws {
        let model = try await makeModel(tracks: [])

        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.isSearching)
    }
}
