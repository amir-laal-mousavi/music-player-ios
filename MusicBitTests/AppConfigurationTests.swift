import XCTest
@testable import MusicBit

final class AppConfigurationTests: XCTestCase {
    func testParseAcceptsNumericIDAndHash() {
        let result = AppConfiguration.parse(apiID: " 12345 ", apiHash: " abcdef012345 ")

        guard case .success(let configuration) = result else {
            return XCTFail("Expected a valid configuration, got \(result)")
        }
        XCTAssertEqual(configuration.apiID, 12345)
        XCTAssertEqual(configuration.apiHash, "abcdef012345")
    }

    func testParseRejectsEmptyValues() {
        XCTAssertEqual(AppConfiguration.parse(apiID: "", apiHash: "hash").failure, .missingAPIID)
        XCTAssertEqual(AppConfiguration.parse(apiID: "123", apiHash: "   ").failure, .missingAPIHash)
    }

    func testParseRejectsUnresolvedBuildPlaceholders() {
        XCTAssertEqual(
            AppConfiguration.parse(apiID: "$(TELEGRAM_API_ID)", apiHash: "hash").failure,
            .missingAPIID
        )
        XCTAssertEqual(
            AppConfiguration.parse(apiID: "123", apiHash: "$(TELEGRAM_API_HASH)").failure,
            .missingAPIHash
        )
    }

    func testParseRejectsNonNumericOrNegativeIdentifiers() {
        XCTAssertEqual(AppConfiguration.parse(apiID: "abc", apiHash: "hash").failure, .invalidAPIID)
        XCTAssertEqual(AppConfiguration.parse(apiID: "0", apiHash: "hash").failure, .invalidAPIID)
        XCTAssertEqual(AppConfiguration.parse(apiID: "-7", apiHash: "hash").failure, .invalidAPIID)
    }

    func testLoadReadsTheConfiguredInfoDictionary() {
        // The test host is the app, so this exercises the real plist lookup without
        // depending on whether the developer supplied Telegram credentials.
        switch AppConfiguration.load() {
        case .success(let configuration):
            XCTAssertGreaterThan(configuration.apiID, 0)
            XCTAssertFalse(configuration.apiHash.isEmpty)
        case .failure(let failure):
            XCTAssertTrue([.missingAPIID, .invalidAPIID, .missingAPIHash].contains(failure))
        }
    }
}

private extension Result where Failure == AppConfiguration.Failure {
    var failure: AppConfiguration.Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
