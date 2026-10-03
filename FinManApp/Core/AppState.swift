import Foundation
import SwiftUI

/// UserDefaults keys for the lightweight profile (everything else lives in SwiftData).
enum ProfileKey {
    static let name = "profile.name"
    static let monthlyIncome = "profile.monthlyIncome"
    static let paydayDay = "profile.paydayDay"
    static let hasOnboarded = "profile.hasOnboarded"
    static let faceIDEnabled = "settings.faceIDEnabled"
}

/// Transient UI state shared across tabs.
@Observable
final class AppState {
    /// Bumped to fire celebratory confetti from anywhere.
    var celebrationTrigger = 0
    var lastError: String?

    func celebrate() { celebrationTrigger += 1 }
}

extension String {
    var initials: String {
        let parts = split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "🙂" : String(parts).uppercased()
    }
}
