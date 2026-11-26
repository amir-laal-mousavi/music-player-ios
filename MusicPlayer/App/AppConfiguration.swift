import Foundation

/// Telegram credentials resolved from build configuration.
///
/// `Config/Base.xcconfig` optionally includes the untracked `Secrets.xcconfig`, and the
/// values reach the app through the `TelegramAPIID` and `TelegramAPIHash` Info.plist keys.
/// Nothing secret is stored in source control.
struct AppConfiguration: Equatable {
    let apiID: Int32
    let apiHash: String

    enum Failure: Error, Equatable {
        case missingAPIID
        case invalidAPIID
        case missingAPIHash
    }

    init(apiID: Int32, apiHash: String) {
        self.apiID = apiID
        self.apiHash = apiHash
    }

    static func load(_ bundle: Bundle = .main) -> Result<AppConfiguration, Failure> {
        let apiID = bundle.object(forInfoDictionaryKey: "TelegramAPIID") as? String ?? ""
        let apiHash = bundle.object(forInfoDictionaryKey: "TelegramAPIHash") as? String ?? ""
        return parse(apiID: apiID, apiHash: apiHash)
    }

    /// Validates raw plist values, including unexpanded `$(...)` build placeholders.
    static func parse(apiID: String, apiHash: String) -> Result<AppConfiguration, Failure> {
        let id = apiID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !id.isEmpty, !id.contains("$(") else { return .failure(.missingAPIID) }
        guard let value = Int32(id), value > 0 else { return .failure(.invalidAPIID) }
        guard !hash.isEmpty, !hash.contains("$(") else { return .failure(.missingAPIHash) }

        return .success(AppConfiguration(apiID: value, apiHash: hash))
    }
}

enum TelegramPaths {
    /// TDLib needs a writable download directory that the app owns.
    static func downloadsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("TelegramDownloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
