import LocalAuthentication
import SwiftUI

/// Optional Face ID / Touch ID / passcode gate shown when the app comes to the foreground.
struct LockScreen: View {
    var unlock: () -> Void
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.brandGradient.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 54, weight: .bold))
                Text("FinMan is locked").font(.title2.bold())
                Button {
                    authenticate()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.white.opacity(0.2), in: .capsule)
                }
                if failed { Text("Couldn't verify it's you. Try again.").font(.footnote) }
            }
            .foregroundStyle(.white)
        }
        .task { authenticate() }
    }

    private func authenticate() {
        Task {
            if await Biometrics.authenticate(reason: "Unlock your finances") {
                unlock()
            } else {
                failed = true
            }
        }
    }
}

enum Biometrics {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
