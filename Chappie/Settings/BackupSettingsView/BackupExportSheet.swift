// BackupExportSheet.swift
// Chappie
//
// Password entry + NSSavePanel flow for exporting the full settings backup
// (providers incl. Keychain secrets, threads, messages, memory). The whole
// file is encrypted — see BackupCrypto in ChappieCore for the scheme.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - BackupExportSheet

struct BackupExportSheet: View {

    var viewModel: ChappieViewModel

    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var isExporting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showSuccess: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var passwordsMatch: Bool { password == confirmPassword }
    private var passwordTooShort: Bool { password.count < 4 }
    private var canExport: Bool { passwordsMatch && !passwordTooShort && !isExporting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("backup_export.title")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
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

                    Text("backup_export.hint")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 13))
                        Text("backup_export.warning")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("backup_export.password_label", systemImage: "lock.fill")
                            .font(.headline)
                        SecureField("backup_export.password_placeholder", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("backup_export.confirm_password_label", systemImage: "lock.fill")
                            .font(.headline)
                        SecureField("backup_export.confirm_password_placeholder", text: $confirmPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !password.isEmpty && passwordTooShort {
                        inlineError("backup_export.password_too_short")
                    } else if !confirmPassword.isEmpty && !passwordsMatch {
                        inlineError("backup_export.password_mismatch")
                    }

                    if showSuccess {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("backup_export.success")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                        .padding(12)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(errorMessage).font(.subheadline).foregroundStyle(.red)
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
                Button("backup_export.cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button {
                    performExport()
                } label: {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView().controlSize(.small)
                            Text("backup_export.exporting")
                        } else {
                            Text("backup_export.export_action")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Inline Error

    private func inlineError(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(key).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Export Flow

    private func performExport() {
        isExporting = true
        errorMessage = nil
        showSuccess = false

        Task {
            do {
                let data = try await viewModel.exportBackup(password: password)
                await MainActor.run {
                    isExporting = false
                    presentSavePanel(data: data)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Runs synchronously on the main thread — fine here since export already finished.
    private func presentSavePanel(data: Data) {
        let panel = NSSavePanel()
        panel.message = String(localized: "backup_export.save_panel_message")
        panel.prompt = String(localized: "backup_export.save_panel_button")
        panel.nameFieldStringValue = defaultFilename()
        if let type = UTType(filenameExtension: "chappiebackup") {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "ChappieBackup-\(formatter.string(from: Date())).chappiebackup"
    }
}
