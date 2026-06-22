// NewThreadProviderSheet+Columns.swift
// Chappie
//
// Two-column picker: left = providers, right = models.

import SwiftUI
import ChappieCore

extension NewThreadProviderSheet {

    // MARK: - Picker Columns

    var pickerColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            providerColumn
                .frame(width: 200)
            Divider()
            modelColumn
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Provider Column

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("new_thread.provider_column")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(providers) { provider in
                        ProviderPickRow(
                            provider: provider,
                            isSelected: selectedProviderId == provider.id,
                            onSelect: {
                                selectedProviderId = provider.id
                                selectedModelName = ""
                                selectedKeyId = provider.requiresApiKey
                                    ? provider.keys.first?.id
                                    : nil
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Model Column

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("new_thread.model_column")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if let provider = selectedProvider {
                if provider.models.isEmpty {
                    modelsEmptyState
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(provider.models) { model in
                                ModelPickRow(
                                    model: model.id,
                                    isSelected: selectedModelName == model.id,
                                    onSelect: { selectedModelName = model.id }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }

                Divider()
                manualModelBar
            } else {
                noProviderHint
            }
        }
    }

    // MARK: - Manual Model Bar

    private var manualModelBar: some View {
        HStack(spacing: 6) {
            TextField("new_thread.manual_placeholder", text: .init(
                get: { manualModelInput },
                set: { manualModelInput = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { applyManualModel() }

            Button("OK") { applyManualModel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty States

    private var modelsEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("new_thread.no_models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("new_thread.enter_manually")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noProviderHint: some View {
        VStack {
            Spacer()
            Text("new_thread.select_provider_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    func applyManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedModelName = trimmed
        manualModelInput = ""
    }
}
