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
// sizeThatFits CONTRACT:
//   Returns the ACTUAL used size (max row width × total height), NOT maxWidth.
//   WHY: returning maxWidth causes HStack to treat FlowLayout as a greedy
//   (frame-filling) child — it gets all available space and expands the pill.
//   Returning the real content width lets HStack treat it as intrinsic-sized,
//   so Spacer pushes it only as wide as its content needs.
//   When proposal.width is finite (wrapping context), rows are packed into
//   that width and the height grows — correct wrapping behaviour.
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
        // Use proposed width as the wrap boundary; nil → no wrapping (intrinsic measure)
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        // Track the widest row to report accurate content width
        var maxUsedWidth: CGFloat = 0
        var isFirstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            let requiredX = isFirstInRow ? size.width : currentX + spacing + size.width

            if !isFirstInRow && requiredX > maxWidth {
                // Wrap: commit current row, record its width, start a new row
                maxUsedWidth = max(maxUsedWidth, currentX)
                totalHeight += currentRowHeight + spacing
                currentX = size.width
                currentRowHeight = size.height
            } else {
                // Fits on current row
                currentX = requiredX
                currentRowHeight = max(currentRowHeight, size.height)
            }
            isFirstInRow = false
        }

        // Commit last row
        maxUsedWidth = max(maxUsedWidth, currentX)
        totalHeight += currentRowHeight

        // Return ACTUAL content size, not maxWidth.
        // This makes HStack treat FlowLayout as intrinsic-sized (like Text),
        // so the pill never expands beyond its content.
        return CGSize(width: maxUsedWidth, height: totalHeight)
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

            let nextX = isFirstInRow ? currentX + size.width : currentX + spacing + size.width

            if !isFirstInRow && (nextX - bounds.minX) > maxWidth {
                // Wrap to next row
                currentY += currentRowHeight + spacing
                currentX = bounds.minX
                currentRowHeight = 0
            } else if !isFirstInRow {
                currentX += spacing
            }

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
