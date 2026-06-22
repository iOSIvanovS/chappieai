// MessageBubbleView+Terminal.swift
// Chappie
//
// WHY: Terminal confirmation bubble — isolated from regular message rendering.
// Renders Run/Cancel prompt for .terminalConfirmation messages.

import SwiftUI


extension MessageBubbleView {

    // MARK: - Terminal Confirmation Bubble

    @ViewBuilder
    func terminalConfirmationBubble(id: UUID, command: String, threadId: UUID) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("terminal.confirmation_required")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text(command)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button {
                        viewModel.approveTerminalCommand(messageId: id, command: command)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)

                    Button {
                        viewModel.rejectTerminalCommand(messageId: id, command: command)
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
            )

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
        .id(msg.id)
    }
}
