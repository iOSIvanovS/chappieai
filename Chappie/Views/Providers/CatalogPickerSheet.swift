// CatalogPickerSheet.swift
// Chappie
//
// First screen when adding a provider: choose a built-in preset or enter manually.
//
// FLOW:
// 1. User sees the hardcoded presets (OpenAI, Anthropic, Groq, …) + a "Manual setup" row.
// 2. Tapping a preset → opens AddProviderSheet pre-filled with baseURL, preset id and protocol.
//    Models are never preloaded: the user loads them from the provider or types them in.
// 3. Tapping "Manual setup" → opens AddProviderSheet with blank fields.
// 4. On save → calls onSaved() to reload the parent view.

import SwiftUI
import ChappieCore

// MARK: - CatalogPickerSheet

struct CatalogPickerSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedPreset: BuiltInProvider? = nil  // preset pick → AddProviderSheet
    @State private var showCustom: Bool = false                // custom pick → AddProviderSheet

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            catalogList

            Divider()

            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        // Preset selected
        .sheet(item: $selectedPreset) { preset in
            AddProviderSheet(
                providerStore: providerStore,
                prefilledPreset: preset,
                isOnboarding: isOnboarding,
                onSaved: {
                    selectedPreset = nil
                    onSaved()
                },
                onCancel: { selectedPreset = nil }
            )
        }
        // Custom provider selected
        .sheet(isPresented: $showCustom) {
            AddProviderSheet(
                providerStore: providerStore,
                isOnboarding: isOnboarding,
                onSaved: {
                    showCustom = false
                    onSaved()
                },
                onCancel: { showCustom = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("catalog.title")
                    .font(.title2.bold())
                Text("catalog.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { onCancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Content

    private var catalogList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(BuiltInProviders.all) { preset in
                    CatalogProviderRow(preset: preset) {
                        selectedPreset = preset
                    }
                }

                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                CustomProviderRow {
                    showCustom = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 360)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("catalog.cancel") { onCancel() }
                .keyboardShortcut(.escape)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
