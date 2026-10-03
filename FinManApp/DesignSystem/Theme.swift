import SwiftUI

enum Theme {
    static let brand = Color.accentColor
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.40, green: 0.31, blue: 0.97), Color(red: 0.69, green: 0.32, blue: 0.93), Color(red: 0.98, green: 0.45, blue: 0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let income = Color(red: 0.13, green: 0.73, blue: 0.47)
    static let expense = Color(red: 0.95, green: 0.33, blue: 0.38)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.10)
    static let cornerRadius: CGFloat = 22
}

// MARK: - Currency

extension Decimal {
    func currency(showSign: Bool = false, compact: Bool = false) -> String { doubleValue.currency(showSign: showSign, compact: compact) }
}

extension Double {
    func currency(showSign: Bool = false, compact: Bool = false) -> String {
        let code = Locale.current.currency?.identifier ?? "USD"
        var style = FloatingPointFormatStyle<Double>.Currency(code: code)
        if compact || abs(self) >= 10_000 { style = style.precision(.fractionLength(0)) }
        if showSign { style = style.sign(strategy: .always()) }
        return formatted(style)
    }
}

// MARK: - Category styling

struct CategoryStyle {
    let symbol: String
    let color: Color
    let emoji: String

    static func forName(_ name: String?) -> CategoryStyle {
        switch (name ?? "").lowercased() {
        case let n where n.contains("hous") || n.contains("rent"): .init(symbol: "house.fill", color: .indigo, emoji: "🏠")
        case let n where n.contains("transport") || n.contains("car") || n.contains("gas"): .init(symbol: "car.fill", color: .blue, emoji: "🚗")
        case let n where n.contains("food") || n.contains("grocer") || n.contains("dining") || n.contains("restaurant"): .init(symbol: "fork.knife", color: .orange, emoji: "🍔")
        case let n where n.contains("entertain"): .init(symbol: "popcorn.fill", color: .pink, emoji: "🍿")
        case let n where n.contains("health") || n.contains("medical"): .init(symbol: "heart.fill", color: .red, emoji: "🩺")
        case let n where n.contains("personal"): .init(symbol: "sparkles", color: .purple, emoji: "💅")
        case let n where n.contains("educat"): .init(symbol: "book.fill", color: .brown, emoji: "📚")
        case let n where n.contains("saving") || n.contains("invest"): .init(symbol: "banknote.fill", color: .green, emoji: "🐷")
        case let n where n.contains("debt") || n.contains("credit") || n.contains("loan"): .init(symbol: "creditcard.fill", color: .gray, emoji: "💳")
        case let n where n.contains("travel"): .init(symbol: "airplane", color: .cyan, emoji: "✈️")
        case let n where n.contains("shop"): .init(symbol: "bag.fill", color: .mint, emoji: "🛍️")
        case let n where n.contains("utilit") || n.contains("phone") || n.contains("internet"): .init(symbol: "bolt.fill", color: .yellow, emoji: "💡")
        case let n where n.contains("income") || n.contains("salary") || n.contains("pay"): .init(symbol: "dollarsign.circle.fill", color: Theme.income, emoji: "💰")
        case let n where n.contains("subscri"): .init(symbol: "repeat", color: .teal, emoji: "🔁")
        case let n where n.contains("insur"): .init(symbol: "shield.fill", color: .teal, emoji: "🛡️")
        case let n where n.contains("gift") || n.contains("donat"): .init(symbol: "gift.fill", color: .pink, emoji: "🎁")
        default: .init(symbol: "tag.fill", color: .secondary, emoji: "🏷️")
        }
    }
}

struct CategoryIcon: View {
    let name: String?
    var size: CGFloat = 40

    var body: some View {
        let style = CategoryStyle.forName(name)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.15), in: .rect(cornerRadius: size * 0.32, style: .continuous))
    }
}

// MARK: - Cards

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

struct SectionHeader: View {
    let title: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            if let action {
                Button(action.title, action: action.run).font(.subheadline.weight(.semibold))
            }
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.brandGradient, in: .rect(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Subtle squish on press for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Misc components

struct AmountText: View {
    let amount: Double
    var font: Font = .body.weight(.semibold)
    var colored = true

    var body: some View {
        Text(amount.currency(showSign: amount > 0))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(colored ? (amount > 0 ? Theme.income : Color.primary) : Color.primary)
            .contentTransition(.numericText(value: amount))
    }
}

struct EmptyStateView: View {
    let emoji: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(emoji).font(.system(size: 56))
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(message).font(.footnote)
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.footnote.bold()) }
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
