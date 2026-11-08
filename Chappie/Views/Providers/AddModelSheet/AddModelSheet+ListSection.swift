// AddModelSheet+ListSection.swift
// Chappie
//
// Load controls, search bar, select-all toggle, model list, manual input row.

import SwiftUI
import ChappieCore

extension AddModelSheet {

    // MARK: - Computed

    var existingIds: Set<String> { Set(existingModels.map { $0.id }) }

    var allModels: [AIModel] {
        var result = manualModels
        for m in fetchedModels where !result.contains(where: { $0.id == m.id }) {
            result.append(m)
        }
        return result
    }

    var filteredModels: [AIModel] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    var canSave: Bool { !selectedModelIds.isEmpty }

    var allFilteredSelected: Bool {
        let selectable = filteredModels.filter { !existingIds.contains($0.id) }
        return !selectable.isEmpty && selectable.allSatisfy { selectedModelIds.contains($0.id) }
    }

    // MARK: - Load Controls

    var loadControlsView: some View {
        customLoadControls
    }

    private var customLoadControls: some View {
        HStack(spacing: 12) {
            Button { fetchFromProvider() } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isLoading
                         ? String(localized: "add_models.fetching")
                         : String(localized: "add_models.fetch"))
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)

            if !allModels.isEmpty {
                Text(String(format: String(localized: "provider.models_count"), allModels.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: String(localized: "add_models.selected"), selectedModelIds.count))
                .font(.caption)
                .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Model List Section

    var modelListSection: some View {
        Group {
            if !allModels.isEmpty {
                searchBarView
                selectAllToggle
                Divider()
            }
            modelListContent
        }
    }

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField("provider.models_search_placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private var selectAllToggle: some View {
        Button { toggleSelectAll() } label: {
            HStack(spacing: 6) {
                Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                Text(allFilteredSelected
                     ? String(localized: "provider.models_deselect_all")
                     : String(localized: "provider.models_select_all"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if !searchText.isEmpty {
                    Text(String(format: String(localized: "format.available_count"),
                                filteredModels.filter { !existingIds.contains($0.id) }.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var modelListContent: some View {
        if allModels.isEmpty && !isLoading {
            emptyStateView
        } else if filteredModels.isEmpty && !isLoading {
            noResultsView
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredModels) { model in
                        let isExisting = existingIds.contains(model.id)
                        let isSelected = selectedModelIds.contains(model.id)
                        ModelSelectRow(
                            model: model,
                            isSelected: isSelected,
                            isExisting: isExisting,
                            onToggle: {
                                guard !isExisting else { return }
                                if isSelected { selectedModelIds.remove(model.id) }
                                else { selectedModelIds.insert(model.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 240)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("new_thread.no_models")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("add_models.empty_custom")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("provider.models_nothing_found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Manual Input

    var manualInputView: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            TextField("provider.models_manual_placeholder", text: $manualInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { addManual() }
            Button("common.add") { addManual() }
                .buttonStyle(.bordered)
                .disabled(manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
