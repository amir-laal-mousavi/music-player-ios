import Foundation
import MusicCore
import SwiftData

@Model
final class PersistedFavorite {
    @Attribute(.unique) var trackID: UUID
    var createdAt: Date

    init(trackID: UUID, createdAt: Date = Date()) {
        self.trackID = trackID
        self.createdAt = createdAt
    }
}

@Model
final class PersistedPlaylist {
    @Attribute(.unique) var id: UUID
    var name: String
    var trackIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        trackIDs = playlist.trackIDs
        createdAt = playlist.createdAt
        updatedAt = playlist.updatedAt
    }

    func value() throws -> Playlist {
        do {
            return try Playlist(
                id: id,
                name: name,
                trackIDs: trackIDs,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DomainError.library(.corruptData)
        }
    }

    func update(with playlist: Playlist) {
        name = playlist.name
        trackIDs = playlist.trackIDs
        updatedAt = playlist.updatedAt
    }
}
