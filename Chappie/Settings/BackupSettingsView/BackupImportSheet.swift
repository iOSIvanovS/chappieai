// BackupImportSheet.swift
// Chappie
//
// File picker + password entry + destructive-restore confirmation for importing a
// full settings backup (see BackupExportSheet for the mirrored export flow).
//
// FLOW (two-step confirmation by design — import is destructive, full restore, no merge):
// 1. Pick .chappiebackup file (NSOpenPanel) + enter password → "Decrypt & Preview".
// 2. ChappieViewModel.previewBackup(data:password:) decrypts without applying anything.
//    On success, show bundle summary (exported date, provider/thread counts) + a loud
//    warning that ALL current data will be erased and replaced.
// 3. User explicitly confirms "Restore Now" → ChappieViewModel.importBackup(_:) applies
//    the wipe-then-restore and re-syncs the running app's in-memory state.
//
// Reusable from both SettingsView (regular backup restore) and OnboardingView (restore
// right from the welcome screen, skipping the provider setup wizard entirely) — the
// optional `onImported` closure lets each call site react differently on success.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ChappieCore

// MARK: - BackupImportSheet

struct BackupImportSheet: View {

    var viewModel: ChappieViewModel
    var onImported: (() -> Void)? = nil

    @State private var fileURL: URL? = nil
    @State private var fileData: Data? = nil
    @State private var password: String = ""
    @State private var previewBundle: ChappieExportBundle? = nil
    @State private var isDecrypting: Bool = false
    @State private var isImporting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showSuccess: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var canDecrypt: Bool {
        fileData != nil && !password.isEmpty && !isDecrypting && previewBundle == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("backup_import.hint")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    filePickerRow

                    if previewBundle == nil {
                        passwordSection
                    }

                    if let errorMessage {
                        inlineBanner(errorMessage, icon: "xmark.circle.fill", color: .red)
                    }

                    if let bundle = previewBundle, !showSuccess {
                        previewSection(bundle)
                    }

                    if showSuccess {
                        inlineBanner(String(localized: "backup_import.success"), icon: "checkmark.circle.fill", color: .green)
                    }
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("backup_import.title")
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
    }

    // MARK: - File Picker

    private var filePickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("backup_import.file_label", systemImage: "doc.zipper")
                .font(.headline)

            HStack(spacing: 10) {
                Text(fileURL?.lastPathComponent ?? String(localized: "backup_import.no_file_selected"))
                    .font(.subheadline)
                    .foregroundStyle(fileURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("backup_import.choose_file_action") { presentOpenPanel() }
                    .buttonStyle(.bordered)
                    .disabled(previewBundle != nil)
            }
        }
    }

    // MARK: - Password

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("backup_import.password_label", systemImage: "lock.fill")
                .font(.headline)
            SecureField("backup_import.password_placeholder", text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Preview + Warning

    private func previewSection(_ bundle: ChappieExportBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow(icon: "calendar", text: String(format: String(localized: "backup_import.preview_exported_at"), bundle.exportedAt.formatted(date: .abbreviated, time: .shortened)))
                summaryRow(icon: "cpu", text: String(format: String(localized: "backup_import.preview_providers_count"), bundle.providers.count))
                summaryRow(icon: "bubble.left.and.bubble.right", text: String(format: String(localized: "backup_import.preview_threads_count"), bundle.threads.count))
            }
            .padding(12)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("backup_import.warning_title")
                        .font(.subheadline.weight(.semibold))
                    Text("backup_import.warning_message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func summaryRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.subheadline)
        }
    }

    private func inlineBanner(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.subheadline).foregroundStyle(color)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("backup_import.cancel") { dismiss() }
                .keyboardShortcut(.escape)
            Spacer()

            if showSuccess {
                Button("backup_import.done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            } else if previewBundle != nil {
                Button {
                    performImport()
                } label: {
                    HStack(spacing: 6) {
                        if isImporting {
                            ProgressView().controlSize(.small)
                            Text("backup_import.restoring")
                        } else {
                            Text("backup_import.restore_action")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isImporting)
            } else {
                Button {
                    performDecrypt()
                } label: {
                    HStack(spacing: 6) {
                        if isDecrypting {
                            ProgressView().controlSize(.small)
                            Text("backup_import.decrypting")
                        } else {
                            Text("backup_import.decrypt_action")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDecrypt)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - File Picker

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "backup_import.open_panel_message")
        panel.prompt = String(localized: "backup_import.open_panel_button")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "chappiebackup") {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            fileData = try Data(contentsOf: url)
            fileURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Decrypt

    private func performDecrypt() {
        guard let fileData else { return }
        isDecrypting = true
        errorMessage = nil

        Task {
            do {
                let bundle = try await viewModel.previewBackup(data: fileData, password: password)
                await MainActor.run {
                    isDecrypting = false
                    previewBundle = bundle
                }
            } catch {
                await MainActor.run {
                    isDecrypting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Import

    private func performImport() {
        guard let previewBundle else { return }
        isImporting = true
        errorMessage = nil

        Task {
            do {
                try await viewModel.importBackup(previewBundle)
                await MainActor.run {
                    isImporting = false
                    showSuccess = true
                    onImported?()
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
