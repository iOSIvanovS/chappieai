import SwiftUI
import ChappieCore

struct LicenseActivationView: View {

    @Environment(\.dismiss) var dismiss
    var viewModel: ChappieViewModel

    // Plans state
    @State var plans: [PlanInfo] = []
    @State var isLoadingPlans = true
    @State var plansError = false

    // Currency selection
    @State var selectedCurrency = "USD"
    let currencies = ["USD", "EUR", "RUB"]

    // Email dialog
    @State var pendingPlan: PlanInfo? = nil
    @State var email = ""
    @State var emailError: String? = nil
    @State var isCreatingPayment = false

    // Key activation
    @State var licenseKey = ""
    @State var isActivating = false
    @State var activationError: String? = nil
    @State var didSucceed = false

    let paymentService = PaymentService()

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
}
