import SwiftData
import SwiftUI

/// First-run flow: a quick hello, income details, then start fresh or explore sample data.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ProfileKey.name) private var storedName = ""
    @AppStorage(ProfileKey.monthlyIncome) private var storedIncome = 0.0
    @AppStorage(ProfileKey.paydayDay) private var storedPayday = 1
    @AppStorage(ProfileKey.hasOnboarded) private var hasOnboarded = false

    @State private var step = 0
    @State private var name = ""
    @State private var income: Double?
    @State private var payday = 1
    @State private var startingBalance: Double?
    @State private var floatPhase = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.brandGradient.ignoresSafeArea()
            floatingCoins

            VStack(spacing: 24) {
                Spacer(minLength: 20)
                Group {
                    switch step {
                    case 0: welcome
                    case 1: nameStep
                    default: moneyStep
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                Spacer(minLength: 20)
                pageDots
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .animation(.snappy, value: step)
        .sensoryFeedback(.impact(weight: .light), trigger: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 76, weight: .bold))
                .symbolEffect(.bounce, value: floatPhase)
            Text("FinMan")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
            Text("Budgets, bills and spending, all in your pocket. Everything stays private on this iPhone. 🔒")
                .font(.headline)
                .multilineTextAlignment(.center)
                .opacity(0.9)
            Spacer().frame(height: 12)
            whiteButton("Let's go ✨") { step = 1 }
            Button("Just explore with sample data") { finish(sample: true) }
                .font(.subheadline.weight(.semibold))
                .opacity(0.9)
        }
        .foregroundStyle(.white)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("👋").font(.system(size: 56))
            Text("What should we call you?").font(.largeTitle.bold())
            TextField("", text: $name, prompt: Text("Your first name").foregroundStyle(.white.opacity(0.6)))
                .font(.title2.weight(.semibold))
                .textContentType(.givenName)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit { if !name.isEmpty { step = 2 } }
                .padding(16)
                .background(.white.opacity(0.18), in: .rect(cornerRadius: 16, style: .continuous))
            whiteButton("Next") { step = 2 }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Back") { step = 0 }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { focused = true }
    }

    private var moneyStep: some View {
        let currency = Locale.current.currency?.identifier ?? "USD"
        return VStack(alignment: .leading, spacing: 16) {
            Text("💰").font(.system(size: 56))
            Text("Nice to meet you, \(name)!").font(.title.bold())
            Text("A couple of numbers help us track how you're doing. You can change these anytime.")
                .font(.subheadline).opacity(0.9)

            labeledField("Monthly take-home income") {
                TextField("", value: $income, format: .currency(code: currency), prompt: Text("e.g. 4,500").foregroundStyle(.white.opacity(0.6)))
                    .keyboardType(.decimalPad)
            }
            labeledField("Current balance in your main account") {
                TextField("", value: $startingBalance, format: .currency(code: currency), prompt: Text("e.g. 1,200").foregroundStyle(.white.opacity(0.6)))
                    .keyboardType(.decimalPad)
            }
            HStack {
                Text("Payday").font(.headline)
                Spacer()
                Stepper("Day \(payday)", value: $payday, in: 1...31)
                    .fixedSize()
                    .colorScheme(.dark)
            }
            .padding(16)
            .background(.white.opacity(0.18), in: .rect(cornerRadius: 16, style: .continuous))

            whiteButton("Start fresh 🚀") { finish(sample: false) }
            Button("Fill it with sample data instead") { finish(sample: true) }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Pieces

    private func labeledField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).opacity(0.85)
            field()
                .font(.title3.weight(.semibold))
                .padding(14)
                .background(.white.opacity(0.18), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    private func whiteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Theme.brand)
        }
        .buttonStyle(PressableStyle())
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { i in
                Capsule().fill(.white.opacity(i == step ? 1 : 0.4)).frame(width: i == step ? 22 : 8, height: 8)
            }
        }
    }

    private var floatingCoins: some View {
        GeometryReader { geo in
            ForEach(0..<7, id: \.self) { i in
                Text(["💸", "🪙", "💰", "📈", "💳", "🐷", "✨"][i])
                    .font(.system(size: 28 + CGFloat(i % 3) * 8))
                    .opacity(0.3)
                    .position(
                        x: geo.size.width * [0.1, 0.85, 0.2, 0.9, 0.5, 0.15, 0.75][i],
                        y: geo.size.height * [0.12, 0.08, 0.85, 0.7, 0.95, 0.5, 0.35][i] + (floatPhase ? -14 : 14)
                    )
                    .animation(.easeInOut(duration: 2.4 + Double(i) * 0.3).repeatForever(autoreverses: true), value: floatPhase)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { floatPhase = true }
    }

    private func finish(sample: Bool) {
        storedName = name.trimmingCharacters(in: .whitespaces).isEmpty ? (sample ? "Alex" : "") : name.trimmingCharacters(in: .whitespaces)
        storedIncome = income ?? (sample ? 5_000 : 0)
        storedPayday = payday
        if sample {
            DataStore.loadSampleData(context, monthlyIncome: storedIncome, paydayDay: payday)
        } else {
            context.insert(Account(name: "Checking", kind: "checking", startingBalance: startingBalance ?? 0))
            try? context.save()
        }
        hasOnboarded = true
    }
}
