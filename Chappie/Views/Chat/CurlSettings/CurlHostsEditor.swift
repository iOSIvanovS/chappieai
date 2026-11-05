// CurlHostsEditor.swift
// Chappie
//
// Thread-level Curl-Chappie settings: the on/off switch and the allow-list of hosts.
// Dumb component: edits the bindings it is given, knows nothing about the ViewModel.
// Validation rules live in ChappieCore (CurlValidation) so they are unit-tested.

import SwiftUI
import ChappieCore

struct CurlHostsEditor: View {

    @Binding var enabled: Bool
    @Binding var hosts: [CurlHost]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("thread.settings.curl_section", systemImage: "network")
                .font(.system(size: 13, weight: .semibold))

            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("thread.settings.curl_toggle")
                        .font(.callout)
                    Text("thread.settings.curl_toggle_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if enabled {
                hostsList
            }
        }
    }

    // MARK: - List

    private var hostsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hosts.isEmpty {
                Text("thread.settings.curl_hosts_empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($hosts) { $host in
                hostRow($host)
            }

            Button {
                hosts.append(CurlHost(name: "", origin: "", permission: .readOnly))
            } label: {
                Label("thread.settings.curl_host_add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Row

    private func hostRow(_ host: Binding<CurlHost>) -> some View {
        let value = host.wrappedValue
        let issue = CurlValidation.issue(for: value, in: hosts)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("thread.settings.curl_host_name", text: host.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                TextField("", text: host.origin, prompt: Text(verbatim: "https://dev.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button {
                    hosts.removeAll { $0.id == value.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("thread.settings.curl_host_remove_help")
            }

            HStack(spacing: 6) {
                Picker("thread.settings.curl_permission_picker", selection: host.permission) {
                    ForEach(CurlHostPermission.allCases, id: \.self) { permission in
                        Text(permission.displayName).tag(permission)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                if value.permission == .readAndLogin {
                    TextField("", text: host.loginPath, prompt: Text(verbatim: "/api/login"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            Text(value.permission.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if value.permission == .full {
                Label("thread.settings.curl_full_warning", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
}
