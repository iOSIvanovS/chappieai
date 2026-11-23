// ComputerUseArguments.swift
// ChappieCore
//
// WHY THIS FILE:
// Tool arguments arrive from the model as JSON, and providers routinely quote scalars: "true",
// "400", "12.5". Strict decoding turns one quoted value into a typeMismatch, and every caller here
// falls back to defaults on a failed decode, so ONE quoted value would silently discard all the
// others. These lenient wrappers accept both encodings.

import Foundation

/// Number, or a string holding one.
struct FlexDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self),
           let d = Double(s.trimmingCharacters(in: .whitespaces)) { value = d; return }
        throw DecodingError.typeMismatch(Double.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected number or numeric string"))
    }
}

/// Integer, or a string holding one. A whole-valued float ("3.0", 3.0) counts as an integer.
struct FlexInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self), d == d.rounded() { value = Int(d); return }
        if let s = try? c.decode(String.self) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { value = i; return }
            if let d = Double(t), d == d.rounded() { value = Int(d); return }
        }
        throw DecodingError.typeMismatch(Int.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected int or numeric string"))
    }
}

/// Boolean, or the strings "true"/"false" (any case), or 1/0.
struct FlexBool: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self), i == 0 || i == 1 { value = (i == 1); return }
        if let s = try? c.decode(String.self) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1":  value = true;  return
            case "false", "no", "0":  value = false; return
            default: break
            }
        }
        throw DecodingError.typeMismatch(Bool.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected bool or \"true\"/\"false\""))
    }
}

/// Arguments of computer_screenshot.
struct ComputerScreenshotArguments: Decodable {
    /// Older name of `monitor`, still accepted as a fallback.
    var screen_index: FlexInt?
    var monitor: FlexInt?

    /// A malformed payload still yields a plain overview rather than an error: the model can always
    /// look at the screen, it just does not get the options it garbled.
    static func parse(_ data: Data) -> ComputerScreenshotArguments {
        (try? JSONDecoder().decode(ComputerScreenshotArguments.self, from: data))
            ?? ComputerScreenshotArguments()
    }
}
