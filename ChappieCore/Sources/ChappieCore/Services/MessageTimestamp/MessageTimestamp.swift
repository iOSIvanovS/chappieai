// MessageTimestamp.swift
// ChappieCore
//
// Time labels for user messages, so the model can feel how much time has passed.
//
// WHY ARITHMETIC IS DONE HERE: models are unreliable at date subtraction (month borders,
// time zones). The client computes the gaps; the model only reads them.
// WHY ONLY USER MESSAGES: stamped assistant replies would teach the model to start its own
// replies with an invented stamp. The run duration is shown on the NEXT user stamp instead.
// WHY NOT STORED IN THE MESSAGE TEXT: labels are derived from stored creation times when a
// request is built, so a given message always yields the same label and the provider's prompt
// cache stays valid. The UI never shows them.

import Foundation

/// The minimum of a chat message that labelling needs. ChappieCore does not know the app's ChatMessage.
public struct MessageTimestampEntry: Sendable, Equatable {
    public let id: UUID
    public let isUser: Bool
    /// nil for messages saved before creation times were stored.
    public let createdAt: Date?

    public init(id: UUID, isUser: Bool, createdAt: Date?) {
        self.id = id
        self.isUser = isUser
        self.createdAt = createdAt
    }
}

public enum MessageTimestamp {

    /// Gaps shorter than this are noise and are not mentioned.
    static let minimumReportedGap: TimeInterval = 60

    /// Labels for every user entry that has a creation time. `entries` must be exactly the
    /// messages the model will see, in order, so gaps are measured between visible messages.
    public static func labels(for entries: [MessageTimestampEntry], timeZone: TimeZone = .current) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (index, entry) in entries.enumerated() where entry.isUser {
            guard let date = entry.createdAt else { continue }
            let previous = index > 0 ? entries[index - 1] : nil
            let beforePrevious = index > 1 ? entries[index - 2] : nil
            result[entry.id] = label(date: date, previous: previous, beforePrevious: beforePrevious, timeZone: timeZone)
        }
        return result
    }

    static func label(
        date: Date,
        previous: MessageTimestampEntry?,
        beforePrevious: MessageTimestampEntry?,
        timeZone: TimeZone
    ) -> String {
        var parts = [stamp(date, timeZone: timeZone)]

        if let prevDate = previous?.createdAt {
            let gap = date.timeIntervalSince(prevDate)
            if gap >= minimumReportedGap {
                parts.append("\(duration(gap)) since previous message")
            }
            // Run duration: the assistant reply is stamped when the run finished, the user message
            // before it when the run started. Only meaningful for a user -> assistant pair.
            if previous?.isUser == false, beforePrevious?.isUser == true, let startDate = beforePrevious?.createdAt {
                let run = prevDate.timeIntervalSince(startDate)
                if run >= minimumReportedGap {
                    parts.append("previous reply took \(duration(run))")
                }
            }
        }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    /// `2026-10-27 15:03 +03:00`. Built by hand: locale, calendar and numbering system settings
    /// of the Mac must not change a label that has already been sent (cache).
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let absOffset = abs(offset)
        return String(
            format: "%04d-%02d-%02d %02d:%02d %@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
            sign, absOffset / 3600, (absOffset % 3600) / 60
        )
    }

    /// `2026-10-27`. Same hand-built, locale-independent approach as `stamp`; used for memory entries.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `(created 2026-10-20, updated 2026-10-27)`. Lets the model tell a stale "in progress" note
    /// from a fresh one. The update day is omitted when it equals the creation day.
    /// Stored dates are stable, so the prompt (and the provider cache) does not change between requests.
    public static func entryDates(created: Date, updated: Date, timeZone: TimeZone = .current) -> String {
        let c = day(created, timeZone: timeZone)
        let u = day(updated, timeZone: timeZone)
        return c == u ? "(created \(c))" : "(created \(c), updated \(u))"
    }

    /// `3d 4h`, `23h 10m`, `4m`. Two most significant units; seconds are dropped.
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// Label as its own first line, followed by the text. Empty text leaves the label alone.
    public static func prefixed(_ text: String, with label: String?) -> String {
        guard let label else { return text }
        return text.isEmpty ? label : label + "\n" + text
    }
}
