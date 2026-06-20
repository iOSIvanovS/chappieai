// AddProviderSheet+Step2.swift
// Chappie
//
// Step 2 UI: models list, search, select/deselect, manual add, save error.

import SwiftUI
import ChappieCore

extension AddProviderSheet {

    // MARK: - Step 2: Models

    var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {

            modelsHeader

            if let fetchErr = fetchError, fetchedModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(fetchErr).font(.caption).foregroundStyle(.orange)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            if !allModels.isEmpty {
                modelsSearchBar
                modelsSelectAllRow
                Divider()
            }

            modelsListArea

            Divider()

            manualModelRow

            if let err = saveError {
                errorBanner(err).padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
    }

    // MARK: - Header (fetch controls or catalog info)

    private var modelsHeader: some View {
        Group {
            if !isCatalog {
                HStack(spacing: 12) {
                    Button { fetchModels() } label: {
                        HStack(spacing: 6) {
                            if isFetchingModels { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(isFetchingModels ? String(localized: "provider.models_fetching") : String(localized: "provider.models_fetch"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFetchingModels)

                    if !fetchedModels.isEmpty {
                        Text(String(format: String(localized: "provider.models_fetched_count"), allModels.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(String(format: String(localized: "provider.models_selected_count"), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            } else {
                HStack {
                    Text(String(format: String(localized: "provider.catalog_models_header"), allModels.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "provider.models_selected_count"), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Search Bar

    private var modelsSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
            TextField("provider.models_search_placeholder", text: $modelSearchText)
                .textFieldStyle(.plain).font(.system(size: 13))
            if !modelSearchText.isEmpty {
                Button { modelSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Select All Row

    private var modelsSelectAllRow: some View {
        Button { toggleSelectAll() } label: {
            HStack(spacing: 6) {
                Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                Text(allFilteredSelected ? String(localized: "provider.models_deselect_all") : String(localized: "provider.models_select_all"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if !modelSearchText.isEmpty {
                    Text(String(format: String(localized: "provider.filter_count"), filteredModels.count, allModels.count))
                        .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Models List Area

    @ViewBuilder
    private var modelsListArea: some View {
        if allModels.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cpu").font(.system(size: 32)).foregroundStyle(.secondary.opacity(0.4))
                Text("provider.models_empty").font(.subheadline).foregroundStyle(.secondary)
                Text("provider.models_empty_hint")
                    .font(.caption).foregroundStyle(.secondary.opacity(0.7)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if filteredModels.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary.opacity(0.4))
                Text("provider.models_nothing_found").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredModels) { model in
                        ModelCheckRow(
                            model: model,
                            isSelected: selectedModelIds.contains(model.id),
                            onToggle: {
                                if selectedModelIds.contains(model.id) { selectedModelIds.remove(model.id) }
                                else { selectedModelIds.insert(model.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(maxHeight: 240)
        }
    }

    // MARK: - Manual Model Row

    private var manualModelRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            TextField("provider.models_manual_placeholder", text: $manualModelInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { addManualModel() }
            Button("common.add") { addManualModel() }
                .buttonStyle(.bordered)
                .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
}
