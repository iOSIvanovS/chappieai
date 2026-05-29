// FlowLayout.swift
// Chappie
//
// A custom SwiftUI Layout that arranges children left-to-right,
// wrapping to the next line when the available width is exceeded —
// exactly like CSS `flex-wrap: wrap`.
//
// USAGE:
//   FlowLayout(spacing: 6) {
//       ForEach(items) { item in ChipView(item) }
//   }
//
// WHY NOT LazyVGrid:
//   LazyVGrid with fixed columns forces equal widths on all cells.
//   FlowLayout measures each child's natural size and packs them
//   greedily — each row is filled as tightly as possible before wrapping.
//
// AVAILABILITY: macOS 13+ (Layout protocol requirement).

import SwiftUI

// MARK: - FlowLayout

/// Greedy left-to-right flow layout with automatic line wrapping.
struct FlowLayout: Layout {

    // Horizontal and vertical spacing between items
    var spacing: CGFloat = 6

    // MARK: - Layout protocol

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var isFirstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            // Determine whether this item fits on the current row
            let requiredX = isFirstInRow ? size.width : currentX + spacing + size.width

            if !isFirstInRow && requiredX > maxWidth {
                // Wrap: commit current row height and start a new row
                totalHeight += currentRowHeight + spacing
                currentX = size.width
                currentRowHeight = size.height
            } else {
                // Fits: extend current row
                currentX = requiredX
                currentRowHeight = max(currentRowHeight, size.height)
            }
            isFirstInRow = false
        }

        // Add the last row
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var currentRowHeight: CGFloat = 0
        var isFirstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            // Check if item fits on the current row
            let nextX = isFirstInRow ? currentX + size.width : currentX + spacing + size.width

            if !isFirstInRow && (nextX - bounds.minX) > maxWidth {
                // Wrap to next row
                currentY += currentRowHeight + spacing
                currentX = bounds.minX
                currentRowHeight = 0
            } else if !isFirstInRow {
                currentX += spacing
            }

            // Place the item vertically centered within the row height
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )

            currentX += size.width
            currentRowHeight = max(currentRowHeight, size.height)
            isFirstInRow = false
        }
    }
}
