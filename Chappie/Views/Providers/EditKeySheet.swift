// EditKeySheet.swift
// Chappie
//
// Sheet for adding or editing a named API key on an existing provider.
//
// MODES:
//   Add  — both name and value required.
//   Edit — name and/or value can be changed; leave value empty to keep the current secret.
//
// VALIDATION (all checked before saving):
//   - Name must not be empty.
//   - Name must be unique within the provider (case-insensitive compare).
//   - Value must not be empty when adding; optional when editing.
//   - Value must be unique within the provider (exact match).
//     WHY: local/private providers sometimes reuse keys — we still guard against it.

import SwiftUI
import ChappieCore

// MARK: - EditKeySheet

struct EditKeySheet: View {

    // MARK: - Input

    let provider: AIProvider
    let editingKey: APIKey?            // nil → add mode
    let providerStore: AIProviderStore?
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var keyName: String = ""
    @State private var keyValue: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: - Computed

    private var isEditing: Bool { editingKey != nil }
    private var title: String { isEditing ? "Редактировать ключ" : "Добавить ключ" }

    private var canSave: Bool {
        let nameTrimmed = keyName.trimmingCharacters(in: .whitespaces)
        let valueTrimmed = keyValue.trimmingCharacters(in: .whitespaces)
        guard !nameTrimmed.isEmpty else { return false }
        // In add mode, value is required
        if !isEditing && valueTrimmed.isEmpty { return false }
        return true
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: isEditing ? "key.fill" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Key name field
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Название ключа", systemImage: "tag.fill")
                            .font(.headline)
                        TextField("Например: Рабочий, Личный, Клиент X", text: $keyName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if canSave { save() } }
                        Text("Понятное имя — вы будете выбирать ключ по нему в треде.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Key value field
                    VStack(alignment: .leading, spacing: 8) {
                        Label("API-ключ", systemImage: "key.fill")
                            .font(.headline)
                        HStack(spacing: 8) {
                            Group {
                                if isKeyVisible {
                                    TextField(
                                        isEditing ? "Новое значение (необязательно)" : "sk-...",
                                        text: $keyValue
                                    )
                                } else {
                                    SecureField(
                                        isEditing ? "Новое значение (необязательно)" : "sk-...",
                                        text: $keyValue
                                    )
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                            Button { isKeyVisible.toggle() } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(isEditing
                             ? "Оставьте пустым чтобы сохранить текущий ключ. Ключ хранится в Keychain."
                             : "Ключ будет сохранён в системном Keychain macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(err).font(.subheadline).foregroundStyle(.red)
                        }
                        .padding(12)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                Button("Отмена") { onCancel() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                            Text("Сохраняем...")
                        } else {
                            Text(isEditing ? "Сохранить" : "Добавить ключ")
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prefill() }
    }

    // MARK: - Prefill

    private func prefill() {
        guard let key = editingKey else { return }
        keyName = key.name
        // Value is intentionally left empty — user fills only if they want to change it
    }

    // MARK: - Save

    private func save() {
        let nameTrimmed = keyName.trimmingCharacters(in: .whitespaces)
        let valueTrimmed = keyValue.trimmingCharacters(in: .whitespaces)

        // Validate name uniqueness within provider
        let otherKeys = provider.keys.filter { $0.id != editingKey?.id }
        if otherKeys.contains(where: { $0.name.lowercased() == nameTrimmed.lowercased() }) {
            errorMessage = "Ключ с таким именем уже существует у этого провайдера."
            return
        }

        // Validate value uniqueness within provider (only when a new value is provided)
        if !valueTrimmed.isEmpty {
            // We can't check Keychain values here synchronously, so we pass the check to the async task.
            // The store itself doesn't enforce this — we do it here in the UI.
        }

        guard let store = providerStore else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                if isEditing, let key = editingKey {
                    // Check value uniqueness if new value provided
                    if !valueTrimmed.isEmpty {
                        let isDuplicate = await checkValueDuplicate(
                            value: valueTrimmed,
                            excludingKeyId: key.id,
                            store: store
                        )
                        if isDuplicate {
                            await MainActor.run {
                                isSaving = false
                                errorMessage = "Ключ с таким значением уже добавлен у этого провайдера."
                            }
                            return
                        }
                    }
                    var updated = key
                    updated.name = nameTrimmed
                    try await store.updateKey(
                        updated,
                        newValue: valueTrimmed.isEmpty ? nil : valueTrimmed,
                        forProviderId: provider.id
                    )
                } else {
                    // Add mode — value required, check uniqueness
                    let isDuplicate = await checkValueDuplicate(
                        value: valueTrimmed,
                        excludingKeyId: nil,
                        store: store
                    )
                    if isDuplicate {
                        await MainActor.run {
                            isSaving = false
                            errorMessage = "Ключ с таким значением уже добавлен у этого провайдера."
                        }
                        return
                    }
                    try await store.addKey(
                        name: nameTrimmed,
                        value: valueTrimmed,
                        toProviderId: provider.id
                    )
                }

                await MainActor.run {
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Duplicate Value Check

    /// Checks if any existing key (excluding the one being edited) has the same Keychain value.
    private func checkValueDuplicate(
        value: String,
        excludingKeyId: UUID?,
        store: AIProviderStore
    ) async -> Bool {
        let keysToCheck = provider.keys.filter { $0.id != excludingKeyId }
        for key in keysToCheck {
            if let existing = await store.loadApiKey(for: key.id), existing == value {
                return true
            }
        }
        return false
    }
}
