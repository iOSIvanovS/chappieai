// MarkdownTextView+Table.swift
// Chappie
//
// TableRow wrapper and TableBlockView — separated to keep the main file lean.

import SwiftUI

// MARK: - Stable table row wrapper

struct TableRow: Identifiable {
    let cells: [String]; let index: Int; let id: String
    init(cells: [String], index: Int) {
        self.cells = cells; self.index = index
        self.id = "\(index)_\(cells.joined().hashValue)"
    }
}

// MARK: - Table block

/// CPU-04: Equatable conformance lets EquatableView skip re-render when inputs are unchanged.
/// Tables are the most expensive block to layout — this guard pays off most here.
struct TableBlockView: View, Equatable {

    let headers: [String]; let rows: [[String]]; let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: TableBlockView, rhs: TableBlockView) -> Bool {
        lhs.headers == rhs.headers && lhs.rows == rhs.rows && lhs.fontSize == rhs.fontSize
    }

    private var borderColor: Color      { colorScheme == .dark ? Color(white: 0.3)   : Color(white: 0.75) }
    private var headerBackground: Color { colorScheme == .dark ? Color(white: 0.18)  : Color(white: 0.93) }
    private var rowBackground: Color    { colorScheme == .dark ? Color(white: 0.13)  : Color(white: 0.98) }
    private var altRowBackground: Color { colorScheme == .dark ? Color(white: 0.16)  : Color(white: 0.955) }

    private var tableRows: [TableRow] {
        rows.enumerated().map { TableRow(cells: $0.element, index: $0.offset) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tableRow(cells: headers, isHeader: true, background: headerBackground)
            Divider().background(borderColor)
            ForEach(tableRows) { row in
                tableRow(cells: row.cells, isHeader: false,
                         background: row.index % 2 == 0 ? rowBackground : altRowBackground)
                if row.index < rows.count - 1 { Divider().background(borderColor) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
    }

    @ViewBuilder
    private func tableRow(cells: [String], isHeader: Bool, background: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(paddedCells(cells).enumerated()), id: \.offset) { _, cell in
                InlineTextView(text: cell, fontSize: fontSize - 1, color: .primary,
                               weight: isHeader ? .semibold : .regular)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(background)
    }

    private func paddedCells(_ cells: [String]) -> [String] {
        let count = headers.count
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }
}
