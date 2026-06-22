import SwiftUI
import ChappieCore

extension LicenseActivationView {

    // MARK: - Data Loading

    func loadPlans() async {
        isLoadingPlans = true
        plansError = false
        do {
            plans = try await paymentService.fetchPlans()
        } catch {
            plansError = true
        }
        isLoadingPlans = false
    }

    // MARK: - Payment

    func startPayment(for plan: PlanInfo) {
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

    // MARK: - Key Activation

    func activateKey() {
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

    // MARK: - Validation

    func isValidEmail(_ string: String) -> Bool {
        let regex = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return string.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - PlanRowView

struct PlanRowView: View {

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

struct EmailInputSheet: View {

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
