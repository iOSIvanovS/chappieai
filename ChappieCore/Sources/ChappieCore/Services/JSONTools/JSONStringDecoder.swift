// JSONStringDecoder.swift
// ChappieCore
//
// Turns the bytes between the quotes of a JSON string into a Swift String.

import Foundation

enum JSONStringDecoder {

    /// Decodes the escapes of bytes[from..<to] (quotes excluded).
    static func decode(_ bytes: [UInt8], from: Int, to: Int) -> String {
        guard from < to else { return "" }
        // Most keys and values have no escapes: take the cheap path.
        if !bytes[from..<to].contains(0x5C) {
            return String(decoding: bytes[from..<to], as: UTF8.self)
        }
        var output: [UInt8] = []
        output.reserveCapacity(to - from)
        var index = from
        while index < to {
            let byte = bytes[index]
            guard byte == 0x5C, index + 1 < to else {
                output.append(byte)
                index += 1
                continue
            }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case 0x22: output.append(0x22)
            case 0x5C: output.append(0x5C)
            case 0x2F: output.append(0x2F)
            case 0x62: output.append(0x08)
            case 0x66: output.append(0x0C)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x75:
                var value = hex4(bytes, at: index) ?? 0xFFFD
                index += 4
                // A high surrogate must be followed by \uXXXX holding the low surrogate.
                if (0xD800...0xDBFF).contains(value) {
                    if index + 5 < to, bytes[index] == 0x5C, bytes[index + 1] == 0x75,
                       let low = hex4(bytes, at: index + 2), (0xDC00...0xDFFF).contains(low) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    } else {
                        value = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(value) {
                    value = 0xFFFD
                }
                let scalar = Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
                output.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                output.append(escape)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Four hex digits at `index` as a number, nil when any of them is not a hex digit.
    static func hex4(_ bytes: [UInt8], at index: Int) -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<4 {
            guard let digit = hexValue(bytes[index + offset]) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }
}
