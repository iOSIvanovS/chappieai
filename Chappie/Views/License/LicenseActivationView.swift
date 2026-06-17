import SwiftUI
import ChappieCore

// MARK: - LicenseActivationView

struct LicenseActivationView: View {

    @Environment(\.dismiss) private var dismiss
    var viewModel: ChappieViewModel

    // Plans state
    @State private var plans: [PlanInfo] = []
    @State private var isLoadingPlans = true
    @State private var plansError = false

    // Currency selection
    @State private var selectedCurrency = "USD"
    private let currencies = ["USD", "EUR", "RUB"]

    // Email dialog
    @State private var pendingPlan: PlanInfo? = nil
    @State private var email = ""
    @State private var emailError: String? = nil
    @State private var isCreatingPayment = false

    // Key activation
    @State private var licenseKey = ""
    @State private var isActivating = false
    @State private var activationError: String? = nil
    @State private var didSucceed = false

    private let paymentService = PaymentService()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    plansSection
                    activationSection
                }
                .padding(28)
            }

            closeButton
        }
        .frame(width: 480)
        .sheet(item: $pendingPlan) { plan in
            EmailInputSheet(
                plan: plan,
                currency: selectedCurrency,
                email: $email,
                errorMessage: $emailError,
                isLoading: $isCreatingPayment,
                onConfirm: { startPayment(for: plan) },
                onCancel: { pendingPlan = nil; email = ""; emailError = nil }
            )
        }
        .task { await loadPlans() }
    }

    // MARK: - Close

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            Text("license.choose_plan_title")
                .font(.title2.bold())
            Text("license.choose_plan_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: - Plans

    @ViewBuilder
    private var plansSection: some View {
        if isLoadingPlans {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("license.loading_plans")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if plansError {
            Button { Task { await loadPlans() } } label: {
                Text("license.plans_load_error")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(spacing: 10) {
                currencyPicker
                ForEach(plans) { plan in
                    PlanRowView(
                        plan: plan,
                        currency: selectedCurrency,
                        isHighlighted: plan.id == "pro",
                        onBuy: { pendingPlan = plan }
                    )
                }
            }
        }
    }

    private var currencyPicker: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Text("license.currency_picker_label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(selection: $selectedCurrency) {
                    ForEach(currencies, id: \.self) { Text($0) }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
    }

    // MARK: - Key Activation

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("license.enter_key_label")
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                TextField("license.enter_key_placeholder", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isActivating || didSucceed)

                Button { activateKey() } label: {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("license.activate_button")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating || didSucceed)
            }

            if let error = activationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if didSucceed {
                Label("license.activated_success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.bold())
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func loadPlans() async {
        isLoadingPlans = true
        plansError = false
        do {
            plans = try await paymentService.fetchPlans()
        } catch {
            plansError = true
        }
        isLoadingPlans = false
    }

    private func startPayment(for plan: PlanInfo) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmed) else {
            emailError = String(localized: "license.invalid_email_error")
            return
        }

        isCreatingPayment = true
        emailError = nil

        Task {
            do {
                let result = try await paymentService.createInvoice(
                    plan: plan.id,
                    email: trimmed,
                    currency: selectedCurrency
                )
                isCreatingPayment = false
                pendingPlan = nil
                email = ""
                NSWorkspace.shared.open(result.paymentURL)
            } catch {
                isCreatingPayment = false
                emailError = String(localized: "license.payment_error")
            }
        }
    }

    private func activateKey() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isActivating = true
        activationError = nil

        Task {
            do {
                _ = try await viewModel.activateLicense(key: key)
                isActivating = false
                didSucceed = true
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch {
                isActivating = false
                activationError = String(localized: "license.activation_error")
            }
        }
    }

    private func isValidEmail(_ string: String) -> Bool {
        let regex = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return string.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - PlanRowView

private struct PlanRowView: View {

    let plan: PlanInfo
    let currency: String
    var isHighlighted: Bool = false
    let onBuy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plan.name)
                        .font(.subheadline.bold())
                    if isHighlighted {
                        Text("license.plan_popular_badge")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(plan.features)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let price = plan.price(for: currency) {
                Text(formattedPrice(price, currency: currency))
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }

            Button(action: onBuy) {
                Text("license.buy_button")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(isHighlighted ? .white : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHighlighted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    private func formattedPrice(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2

        switch currency {
        case "RUB": formatter.currencyCode = "RUB"; formatter.currencySymbol = "₽"
        case "USD": formatter.currencyCode = "USD"; formatter.currencySymbol = "$"
        case "EUR": formatter.currencyCode = "EUR"; formatter.currencySymbol = "€"
        default:    formatter.currencyCode = currency
        }

        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}

// MARK: - EmailInputSheet

private struct EmailInputSheet: View {

    let plan: PlanInfo
    let currency: String
    @Binding var email: String
    @Binding var errorMessage: String?
    @Binding var isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("license.email_dialog_title")
                    .font(.title3.bold())
                Text("license.email_dialog_message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("license.email_placeholder", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .disabled(isLoading)
                .onSubmit { if !isLoading { onConfirm() } }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("common.cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)

                Button {
                    onConfirm()
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("license.proceed_to_payment_button")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}
