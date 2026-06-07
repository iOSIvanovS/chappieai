// ChappieError.swift
// ChappieCore

import Foundation

/// Centralized error enum for all ChappieCore failures.
public enum ChappieError: LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case parsingError(String)
    case memoryError(String)
    case aiContextLimitExceeded

    /// URLSession throws URLError(.cancelled) when a Swift Task is cancelled mid-stream.
    /// This is NOT a user-facing error — ViewModel catches it and silently stops.
    case cancelled

    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let msg):       return "Network error: \(msg)"
        case .fileSystemError(let msg):    return "File system error: \(msg)"
        case .parsingError(let msg):       return "Data parsing error: \(msg)"
        case .memoryError(let msg):        return "Database memory error: \(msg)"
        case .aiContextLimitExceeded:      return "AI context limit exceeded. Please clear history or reduce file sizes."
        case .cancelled:                   return "Request cancelled."
        case .unknown(let msg):            return "Unknown error: \(msg)"
        }
    }
}
