import SwiftUI

struct AuthView: View {
    @Environment(AppModel.self) private var model

    @State private var isRegistering = false
    @State private var email = ""
    @State private var password = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showServerSettings = false
    @State private var floatPhase = false

    @FocusState private var focus: Field?
    private enum Field { case first, last, email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && (!isRegistering || !firstName.isEmpty)
    }

    var body: some View {
        ZStack {
            Theme.brandGradient.ignoresSafeArea()
            floatingCoins

            ScrollView {
                VStack(spacing: 28) {
                    header.padding(.top, 48)
                    form
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showServerSettings) { ServerSettingsSheet() }
        .sensoryFeedback(.error, trigger: error)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: isRegistering)
            Text("FinMan")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(isRegistering ? "Let's get your money organised ✨" : "Welcome back! Your money missed you 👋")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.opacity)
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            Picker("Mode", selection: $isRegistering.animation(.snappy)) {
                Text("Sign in").tag(false)
                Text("Create account").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            if isRegistering {
                HStack(spacing: 10) {
                    field("First name", text: $firstName, icon: "person.fill")
                        .focused($focus, equals: .first)
                        .textContentType(.givenName)
                    field("Last name", text: $lastName, icon: nil)
                        .focused($focus, equals: .last)
                        .textContentType(.familyName)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            field("Email", text: $email, icon: "envelope.fill")
                .focused($focus, equals: .email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20)
                SecureField("Password (6+ characters)", text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            .fieldBackground()

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.expense)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button(action: submit) {
                ZStack {
                    Text(isRegistering ? "Create account" : "Sign in").opacity(isWorking ? 0 : 1)
                    if isWorking { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit || isWorking)
            .padding(.top, 4)

            HStack {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Text("or").font(.footnote).foregroundStyle(.secondary)
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }

            Button {
                run { try await model.demoLogin() }
            } label: {
                Label("Explore with demo data", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(isWorking)

            Button {
                showServerSettings = true
            } label: {
                Label(model.api.baseURL, systemImage: "server.rack")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 30, y: 12)
    }

    private func field(_ title: String, text: Binding<String>, icon: String?) -> some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20) }
            TextField(title, text: text)
        }
        .fieldBackground()
    }

    private var floatingCoins: some View {
        GeometryReader { geo in
            ForEach(0..<7, id: \.self) { i in
                Text(["💸", "🪙", "💰", "📈", "💳", "🐷", "✨"][i])
                    .font(.system(size: 28 + CGFloat(i % 3) * 8))
                    .opacity(0.35)
                    .position(
                        x: geo.size.width * [0.1, 0.85, 0.2, 0.9, 0.5, 0.15, 0.75][i],
                        y: geo.size.height * [0.12, 0.08, 0.85, 0.7, 0.95, 0.5, 0.35][i] + (floatPhase ? -14 : 14)
                    )
                    .animation(.easeInOut(duration: 2.4 + Double(i) * 0.3).repeatForever(autoreverses: true), value: floatPhase)
            }
        }
        .ignoresSafeArea()
        .onAppear { floatPhase = true }
    }

    private func submit() {
        guard canSubmit else { return }
        run {
            if isRegistering {
                try await model.register(email: email, password: password, firstName: firstName, lastName: lastName)
            } else {
                try await model.login(email: email, password: password)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        focus = nil
        isWorking = true
        withAnimation { error = nil }
        Task {
            do {
                try await work()
            } catch APIError.unauthorized {
                withAnimation { error = "That email and password don't match." }
            } catch {
                withAnimation { self.error = error.localizedDescription }
            }
            isWorking = false
        }
    }
}

private extension View {
    func fieldBackground() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct ServerSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://localhost:8080", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server address")
                } footer: {
                    Text("The FinManApp Spring Boot backend. Use http://localhost:8080 in the Simulator, or your Mac's LAN IP on a device.")
                }
                Section {
                    Button("Reset to default") { url = APIClient.defaultBaseURL }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.api.baseURL = url
                        dismiss()
                    }
                    .disabled(URL(string: url)?.scheme == nil)
                }
            }
            .onAppear { url = model.api.baseURL }
        }
        .presentationDetents([.medium])
    }
}
