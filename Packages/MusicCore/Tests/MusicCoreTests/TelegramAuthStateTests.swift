@testable import MusicCore
import XCTest

final class TelegramAuthStateTests: XCTestCase {
    private let states: [TelegramAuthState] = [
        .unauthenticated,
        .waitingForPhone,
        .waitingForCode,
        .waitingForPassword,
        .authenticated,
        .loggingOut,
        .failure(.telegram(.networkUnavailable))
    ]

    private let allowed: [(TelegramAuthState, TelegramAuthState)] = [
        (.unauthenticated, .waitingForPhone),
        (.unauthenticated, .authenticated),
        (.unauthenticated, .failure),
        (.waitingForPhone, .waitingForCode),
        (.waitingForPhone, .authenticated),
        (.waitingForPhone, .failure),
        (.waitingForCode, .waitingForPassword),
        (.waitingForCode, .authenticated),
        (.waitingForCode, .failure),
        (.waitingForPassword, .authenticated),
        (.waitingForPassword, .failure),
        (.authenticated, .loggingOut),
        (.authenticated, .failure),
        (.loggingOut, .unauthenticated),
        (.loggingOut, .authenticated),
        (.loggingOut, .failure),
        (.failure, .unauthenticated)
    ]

    func testOnlyDocumentedAuthenticationTransitionsAreAllowed() throws {
        for from in states {
            for to in states {
                let isAllowed = allowed.contains { $0.0 == from && $0.1 == to }
                XCTAssertEqual(from.canTransition(to: to), isAllowed, "\(from) -> \(to)")
                if isAllowed {
                    XCTAssertEqual(try from.transition(to: to), to)
                } else {
                    XCTAssertThrowsError(try from.transition(to: to)) { error in
                        XCTAssertEqual(
                            error as? DomainError,
                            .invalidStateTransition(
                                from: String(describing: from),
                                to: String(describing: to)
                            )
                        )
                    }
                }
            }
        }
    }

    func testFailureCanRestartAuthentication() throws {
        let failed = TelegramAuthState.failure(.telegram(.networkUnavailable))
        XCTAssertEqual(try failed.transition(to: .unauthenticated), .unauthenticated)
        XCTAssertThrowsError(try failed.transition(to: .authenticated))
    }

    func testAuthenticationInputValidation() throws {
        XCTAssertEqual(try validatedPhoneNumber(" +1 555 0100 \n"), "+1 555 0100")
        XCTAssertEqual(try validatedAuthenticationCode(" 12345 "), "12345")
        XCTAssertEqual(try validatedPassword(" test password "), " test password ")
        XCTAssertThrowsError(try validatedPhoneNumber(" \n")) { error in
            XCTAssertEqual(error as? DomainError, .invalidPhoneNumber)
        }
        XCTAssertThrowsError(try validatedAuthenticationCode("")) { error in
            XCTAssertEqual(error as? DomainError, .invalidAuthenticationCode)
        }
        XCTAssertThrowsError(try validatedPassword("")) { error in
            XCTAssertEqual(error as? DomainError, .invalidPassword)
        }
    }
}
