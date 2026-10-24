// StorageIssueBanner.swift
// Chappie
//
// Non-blocking notice shown when stored data was found damaged. Informs only — a backup copy
// already exists, so nothing here needs an immediate decision.

import SwiftUI

struct StorageIssueBanner: View {

    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("storage_issue.dismiss", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
