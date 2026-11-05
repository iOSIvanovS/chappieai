// ThreadSettingsSheet+Header+Footer.swift
// Chappie
//
// Header, footer, and shared helper views for ThreadSettingsSheet.

import SwiftUI
import ChappieCore

extension ThreadSettingsSheet {

    // MARK: - Header

    var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gear")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("thread.settings.title")
                    .font(.headline)
                Text(draftTitle.isEmpty ? String(localized: "thread.settings.untitled") : draftTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Footer

    var footerView: some View {
        HStack {
            Button("thread.settings.cancel") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("thread.settings.save") {
                let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalTitle = trimmedTitle.isEmpty ? thread.title : trimmedTitle
                var updatedSettings = draftSettings

                // For keyless providers (e.g. Ollama) — preserve the original keyId unchanged.
                let effectiveKeyId: UUID?
                if let provider = activeProvider, provider.requiresApiKey {
                    effectiveKeyId = draftKeyId
                } else {
                    effectiveKeyId = thread.settings.activeKeyId
                }

                updatedSettings.activeKeyId = effectiveKeyId
                // Store exactly what request matching compares against (see CurlOrigin).
                updatedSettings.curlHosts = CurlValidation.normalized(CurlValidation.droppingBlank(updatedSettings.curlHosts))

                print("[ThreadSettingsSheet] onSave: title='\(finalTitle)' maxMsgs=\(updatedSettings.maxMessagesInContext) keyId=\(effectiveKeyId?.uuidString ?? "nil") terminal=\(updatedSettings.terminalAccess.rawValue)")

                onSave(finalTitle, updatedSettings, nil, effectiveKeyId, nil)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draftSettings.curlHostsAreSaveable)
        }
        .padding(16)
    }

    // MARK: - Shared Helpers

    func sectionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    func infoRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func infoRow(icon: String, color: AnyShapeStyle, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
