// DocumentTools+XMLNormalization.swift
// ChappieMCP
//
// WHY THIS FILE:
// Word splits text runs aggressively for spell-check / track-changes metadata:
//   <w:r><w:t>Ива</w:t></w:r><w:r><w:t>нов</w:t></w:r>
// We strip revision noise (rsid* attrs, proofErr tags) without touching content,
// making the XML readable and editable for AI.

import Foundation

extension DocumentTools {

    // MARK: - Office XML normalization

    /// Entry point — only normalizes Word XML entries, passes others through unchanged.
    func normalizeOfficeXML(_ xml: String, entryName: String) -> String {
        guard entryName.hasSuffix(".xml") else { return xml }
        guard entryName.hasPrefix("word/") else { return xml }
        return mergeAdjacentWordRuns(xml)
    }

    private func mergeAdjacentWordRuns(_ xml: String) -> String {
        var result = xml
        result = removeXMLAttributes(result, matching: ["w:rsidR", "w:rsidRPr", "w:rsidDel", "w:rsidRDefault"])
        result = removeXMLElements(result, tags: ["w:proofErr", "w:bookmarkStart", "w:bookmarkEnd"])
        return result
    }

    private func removeXMLAttributes(_ xml: String, matching attrNames: [String]) -> String {
        var result = xml
        for attr in attrNames {
            var output = ""
            var i = result.startIndex
            while i < result.endIndex {
                if result[i...].hasPrefix(attr) {
                    let afterAttr = result.index(i, offsetBy: attr.count, limitedBy: result.endIndex) ?? result.endIndex
                    var j = afterAttr
                    while j < result.endIndex && result[j] == " " { j = result.index(after: j) }
                    if j < result.endIndex && result[j] == "=" {
                        j = result.index(after: j)
                        if j < result.endIndex && result[j] == "\"" {
                            j = result.index(after: j)
                            while j < result.endIndex && result[j] != "\"" { j = result.index(after: j) }
                            if j < result.endIndex { j = result.index(after: j) }
                            if let prev = output.indices.last, output[prev] == " " {
                                output.removeLast()
                            }
                            i = j
                            continue
                        }
                    }
                }
                output.append(result[i])
                i = result.index(after: i)
            }
            result = output
        }
        return result
    }

    private func removeXMLElements(_ xml: String, tags: [String]) -> String {
        var result = xml
        for tag in tags {
            var output = ""
            var i = result.startIndex
            while i < result.endIndex {
                if result[i] == "<" {
                    let afterBracket = result.index(after: i)
                    if result[afterBracket...].hasPrefix(tag) {
                        var j = afterBracket
                        while j < result.endIndex && result[j] != ">" { j = result.index(after: j) }
                        if j < result.endIndex {
                            j = result.index(after: j)
                            i = j
                            continue
                        }
                    }
                }
                output.append(result[i])
                i = result.index(after: i)
            }
            result = output
        }
        return result
    }
}
