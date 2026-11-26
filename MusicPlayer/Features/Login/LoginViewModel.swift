import Foundation
import MusicCore
import Observation

@MainActor
@Observable
final class LoginViewModel {
    private let gateway: any TelegramGateway
    private var observation: Task<Void, Never>?
    private var hasStarted = false

    var phone = ""
    var code = ""
    var password = ""
    var phase: TelegramAuthState = .unauthenticated
    var account: TelegramAccount?
    var errorMessage: String?
    var isSubmitting = false

    init(gateway: any TelegramGateway) {
        self.gateway = gateway
    }

    var isAuthenticated: Bool {
        phase == .authenticated || phase == .loggingOut
    }

    var needsPhone: Bool {
        phase == .waitingForPhone || phase == .unauthenticated
    }

    var needsCode: Bool { phase == .waitingForCode }
    var needsPassword: Bool { phase == .waitingForPassword }

    var canSubmit: Bool {
        guard !isSubmitting else { return false }
        if needsPhone { return !trimmed(phone).isEmpty }
        if needsCode { return !trimmed(code).isEmpty }
        if needsPassword { return !password.isEmpty }
        return false
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let gateway = self.gateway
        observation = Task { [weak self] in
            for await state in gateway.observeAuthState() {
                guard let self else { return }
                self.apply(state)
            }
        }
        phase = await gateway.authState
        account = await gateway.currentAccount
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func submit() async {
        switch phase {
        case .waitingForCode:
            await run { try await self.gateway.submitCode(self.code) }
        case .waitingForPassword:
            await run { try await self.gateway.submitPassword(self.password) }
        default:
            await run { try await self.gateway.submitPhone(self.phone) }
        }
    }

    func logout() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await gateway.logout()
            account = nil
            code = ""
            password = ""
            phase = await gateway.authState
        } catch {
            errorMessage = userMessage(for: error)
        }
        isSubmitting = false
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await operation()
            phase = await gateway.authState
            account = await gateway.currentAccount
            code = ""
            password = ""
        } catch {
            errorMessage = userMessage(for: error)
            phase = await gateway.authState
        }
        isSubmitting = false
    }

    private func apply(_ state: TelegramAuthState) {
        phase = state
        switch state {
        case .authenticated:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.userMessage
        default:
            break
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
