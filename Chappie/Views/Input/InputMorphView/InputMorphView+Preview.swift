// InputMorphView+Preview.swift
// Chappie

import SwiftUI

#Preview("Idle — empty") {
    let streaming = StreamingState()
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 160)
}

#Preview("Idle — multiline") {
    let streaming = StreamingState()
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant("Line 1\nLine 2\nLine 3\nLine 4\nLine 5"),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 260)
}

#Preview("Thinking — tool call") {
    let streaming = StreamingState()
    streaming.isThinking = true
    streaming.currentToolCall = "write_file → Chappie/Views/Input/InputMorphView.swift"
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 120)
}
