import SwiftUI

struct LoginView: View {
    @Bindable var model: LoginViewModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case phone
        case code
        case password
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
                if let errorMessage = model.errorMessage {
                    StatusBanner(kind: .error, message: errorMessage)
                        .accessibilityIdentifier("login.error")
                }
                Text("Your Telegram session stays on this device. MusicPlayer never posts, forwards, or shares anything, and imported music plays without a connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.heroGradient)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            Text(stepTitle)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            Text(stepSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.needsCode {
            codeForm
        } else if model.needsPassword {
            passwordForm
        } else {
            phoneForm
        }
    }

    private var phoneForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledField(title: "Phone number", systemImage: "phone") {
                TextField("+1 555 010 1234", text: $model.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focusedField, equals: .phone)
                    .submitLabel(.continue)
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("login.phone")
            }

            submitButton(title: "Send code")
                .accessibilityIdentifier("login.submit")
        }
        .padding(16)
        .glassCard()
        .onAppear { focusedField = .phone }
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledField(title: "Login code", systemImage: "number") {
                TextField("12345", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .code)
                    .submitLabel(.continue)
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("login.code")
            }

            submitButton(title: "Verify code")
                .accessibilityIdentifier("login.submit")

            Text("Telegram sent the code to the app and to your other signed-in devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard()
        .onAppear { focusedField = .code }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledField(title: "Two-step password", systemImage: "lock") {
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("login.password")
            }

            submitButton(title: "Sign in")
                .accessibilityIdentifier("login.submit")
        }
        .padding(16)
        .glassCard()
        .onAppear { focusedField = .password }
    }

    private func submitButton(title: String) -> some View {
        Button {
            Task { await model.submit() }
        } label: {
            if model.isSubmitting {
                ProgressView()
                    .tint(.white)
            } else {
                Text(title)
            }
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(!model.canSubmit)
    }

    private var stepTitle: String {
        if model.needsCode { return "Enter the code" }
        if model.needsPassword { return "Two-step verification" }
        return "Sign in to Telegram"
    }

    private var stepSubtitle: String {
        if model.needsCode { return "Telegram sent a login code to your account." }
        if model.needsPassword { return "This account is protected by a two-step password." }
        return "Use your own Telegram account to read audio from your chats. Sign in once; the session is kept on this device."
    }
}
