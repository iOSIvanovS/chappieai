// ProviderDetailView+Sections.swift
// Chappie
//
// UI sections: provider info card, keys section, models section.

import SwiftUI
import ChappieCore

extension ProviderDetailView {

    // MARK: - Provider Info Card

    var providerInfoCard: some View {
        HStack(spacing: 16) {
            ProviderIconView(
                iconName: currentProvider.iconName,
                iconColor: currentProvider.resolvedIconColor,
                size: 44
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(currentProvider.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    if currentProvider.isFromCatalog {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .help("providers.catalog_from")
                    }

                    if currentProvider.origin == .custom {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Text(currentProvider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }

    // MARK: - Keys Section

    var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("providers.keys_section")
                    .font(.headline)
                Text(verbatim: "(\(currentProvider.keys.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddKey = true } label: {
                    Label("providers.keys_add", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.keys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("providers.keys_empty")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 2) {
                    ForEach(currentProvider.keys) { key in
                        KeyRow(
                            key: key,
                            onEdit: { editingKey = key },
                            onDelete: { deleteKeyId = key.id }
                        )
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Models Section

    var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("providers.models_section")
                    .font(.headline)
                Text(verbatim: "(\(currentProvider.models.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddModel = true } label: {
                    Label("providers.models_add", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("providers.models_empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(currentProvider.models) { model in
                        ModelRow(
                            model: model,
                            onDelete: { deleteModelId = model.id }
                        )
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
