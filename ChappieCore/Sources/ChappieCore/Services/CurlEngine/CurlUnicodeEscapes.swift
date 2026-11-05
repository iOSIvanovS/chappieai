// CurlUnicodeEscapes.swift
// ChappieCore
//
// Many servers send JSON with every non-ASCII character as \uXXXX, which is unreadable for the model.
// Only escapes above ASCII are decoded: \u0022 (a quote) or \u005c (a backslash) would change the
// JSON structure, so they stay as written. `\\u0422` is an escaped backslash followed by plain text
// and is left alone. Unpaired surrogates and malformed escapes stay as written as well.

import Foundation

enum CurlUnicodeEscapes {

    static func decode(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let current = scalars[i]
            guard current == "\\", i + 1 < scalars.count else {
                out.append(current)
                i += 1
                continue
            }
            guard scalars[i + 1] == "u", let unit = hex4(scalars, at: i + 2) else {
                // Any other escape (\\, \", \n ...) is copied as a pair so it cannot start a \u.
                out.append(current)
                out.append(scalars[i + 1])
                i += 2
                continue
            }

            var consumed = 6
            var decoded: Unicode.Scalar?
            if unit >= 0x80 && !(0xD800...0xDFFF).contains(unit) {
                decoded = Unicode.Scalar(unit)
            } else if (0xD800...0xDBFF).contains(unit),
                      i + 12 <= scalars.count,
                      scalars[i + 6] == "\\", scalars[i + 7] == "u",
                      let low = hex4(scalars, at: i + 8), (0xDC00...0xDFFF).contains(low) {
                decoded = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                consumed = 12
            }

            if let decoded {
                out.append(decoded)
            } else {
                out.append(contentsOf: scalars[i..<min(i + 6, scalars.count)])
                consumed = 6
            }
            i += consumed
        }
        return String(out)
    }

    private static func hex4(_ scalars: [Unicode.Scalar], at start: Int) -> UInt32? {
        guard start + 4 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for scalar in scalars[start..<start + 4] {
            guard let digit = Character(scalar).hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
        }
        return value
    }
}
