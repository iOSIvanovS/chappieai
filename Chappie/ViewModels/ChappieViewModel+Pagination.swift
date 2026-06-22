// ChappieViewModel+Pagination.swift
// Chappie
//
// In-memory pagination: resetPagination, loadMoreMessages, appendToDisplayed.

import Foundation

extension ChappieViewModel {

    func resetPagination(fireScrollTrigger: Bool = false) {
        let count = messages.count
        if count <= pageSize {
            displayedStart = 0
            displayedMessages = messages
            hasMoreMessages = false
        } else {
            displayedStart = count - pageSize
            displayedMessages = Array(messages[displayedStart...])
            hasMoreMessages = true
        }
        if fireScrollTrigger { scrollToBottomTrigger += 1 }
    }

    func loadMoreMessages() {
        guard hasMoreMessages, displayedStart > 0 else { return }
        let newStart = max(0, displayedStart - pageSizeLoad)
        let additional = Array(messages[newStart..<displayedStart])
        guard !additional.isEmpty else { return }

        loadMoreAnchorId = displayedMessages.first?.id

        displayedStart = newStart
        displayedMessages = additional + displayedMessages
        hasMoreMessages = displayedStart > 0
    }

    func appendToDisplayed(_ message: ChatMessage) {
        displayedMessages.append(message)
        // Trim oldest from the top to keep memory bounded during long active sessions.
        if displayedMessages.count > maxDisplayed {
            let excess = displayedMessages.count - maxDisplayed
            displayedMessages = Array(displayedMessages.dropFirst(excess))
            displayedStart += excess
            hasMoreMessages = displayedStart > 0
        }
    }
}
