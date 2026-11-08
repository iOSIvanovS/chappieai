// AddModelSheet.swift
// Chappie
//
// Main view for adding models to a provider.
// Delegates logic to AddModelSheet+Logic, row UI to ModelSelectRow.

import SwiftUI
import ChappieCore

// MARK: - AddModelSheet

struct AddModelSheet: View {

    // MARK: - Input

    let provider: AIProvider
    let existingModels: [AIModel]
    let providerStore: AIProviderStore?
    let onSaved: ([AIModel]) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State var fetchedModels: [AIModel] = []
    @State var manualModels: [AIModel] = []
    @State var selectedModelIds: Set<String> = []
    @State var manualInput: String = ""
    @State var searchText: String = ""
    @State var isLoading: Bool = false
    @State var loadError: String? = nil
    @State var isSaving: Bool = false
    @State var saveError: String? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            loadControlsView
            if let err = loadError { errorBanner(err) }
            Divider()
            modelListSection
            Divider()
            manualInputView
            if let err = saveError { saveBanner(err) }
            Divider()
            footerView
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "plus.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("add_models.title")
                    .font(.title2.bold())
                Text(provider.displayName)
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

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("add_models.cancel") { onCancel() }
                .keyboardShortcut(.escape)
            Spacer()
            Button {
                confirmSave()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                        Text("add_models.adding")
                    } else {
                        Text(String(format: String(localized: "add_models.add_count"), selectedModelIds.count))
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Error Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.orange)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func saveBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline).foregroundStyle(.red)
        }
        .padding(.horizontal, 24)
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
    }
}
