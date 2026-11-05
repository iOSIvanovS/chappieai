// CurlSecretsEditor.swift
// Chappie
//
// Project-level Curl-Chappie settings: the list of named secrets.
// Metadata is edited through `secrets`; typed values go into `values` and are written to the
// Keychain only when the project sheet is saved (Cancel discards them). Stored values are
// never read back into the UI — an empty field with a "saved" placeholder means "keep".

import SwiftUI
import ChappieCore

struct CurlSecretsEditor: View {

    @Binding var secrets: [CurlSecret]
    /// Values typed this session: secret id → field → text.
    @Binding var values: [UUID: [CurlSecretField: String]]
    /// Thread hosts available for binding.
    let hosts: [CurlHost]
    /// "<secretId>.<field>" for every value that already exists in the Keychain.
    let savedFields: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("project.settings.curl_section", systemImage: "key.viewfinder")
                .font(.system(size: 13, weight: .semibold))

            Text("project.settings.curl_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if listedOrigins.isEmpty {
                Label("project.settings.curl_no_hosts", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($secrets) { $secret in
                secretRow($secret)
            }

            Button {
                secrets.append(CurlSecret(name: "", kind: .loginPassword, hostOrigin: listedOrigins.first?.origin ?? ""))
            } label: {
                Label("project.settings.curl_secret_add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Hosts for the picker

    private struct HostChoice: Hashable { let origin: String; let title: String }

    private var listedOrigins: [HostChoice] {
        hosts.compactMap { host in
            guard let origin = CurlOrigin.normalize(host.origin) else { return nil }
            return HostChoice(origin: origin, title: "\(host.name) — \(origin)")
        }
    }

    // MARK: - Row

    private func secretRow(_ secret: Binding<CurlSecret>) -> some View {
        let value = secret.wrappedValue
        let issue = CurlValidation.issue(for: value, in: secrets)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("project.settings.curl_secret_name", text: secret.name)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: secret.kind) {
                    ForEach(CurlSecretKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Button {
                    secrets.removeAll { $0.id == value.id }
                    values[value.id] = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("project.settings.curl_secret_remove_help")
            }

            hostPicker(secret)

            if value.kind == .customHeader {
                TextField("", text: secret.headerName, prompt: Text(verbatim: "X-Api-Key"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            ForEach(value.kind.fields, id: \.self) { field in
                valueField(secretId: value.id, field: field)
            }

            if let issue {
                Label(issue.message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func hostPicker(_ secret: Binding<CurlSecret>) -> some View {
        let current = CurlOrigin.normalize(secret.wrappedValue.hostOrigin) ?? secret.wrappedValue.hostOrigin
        let known = listedOrigins.contains { $0.origin == current }

        return Picker("project.settings.curl_secret_host", selection: secret.hostOrigin) {
            if current.isEmpty {
                Text("project.settings.curl_host_pick").tag("")
            } else if !known {
                // Bound to a host that this thread does not list — keep it visible instead of silently rebinding.
                Text(String(format: String(localized: "project.settings.curl_host_unlisted"), current)).tag(secret.wrappedValue.hostOrigin)
            }
            ForEach(listedOrigins, id: \.self) { choice in
                Text(choice.title).tag(choice.origin)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Value field

    @ViewBuilder
    private func valueField(secretId: UUID, field: CurlSecretField) -> some View {
        let typed = values[secretId]?[field] ?? ""
        let saved = savedFields.contains("\(secretId.uuidString).\(field.rawValue)")
        let binding = Binding<String>(
            get: { values[secretId]?[field] ?? "" },
            set: { values[secretId, default: [:]][field] = $0 }
        )

        VStack(alignment: .leading, spacing: 2) {
            // Secure for every part: a login is stored in the Keychain next to its password
            // and is never shown again, so there is nothing to display in plain text.
            SecureField(field.label, text: binding,
                        prompt: Text(saved ? String(localized: "project.settings.curl_value_saved") : field.label))
            if !saved && typed.isEmpty {
                Text("project.settings.curl_value_missing")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
