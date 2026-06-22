import SwiftUI
import ChappieCore

extension LicenseActivationView {

    // MARK: - Header

    var headerSection: some View {
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
    var plansSection: some View {
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

    var currencyPicker: some View {
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

    var activationSection: some View {
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
}
