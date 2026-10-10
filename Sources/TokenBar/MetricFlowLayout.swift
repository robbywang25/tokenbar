import SwiftUI

struct MetricFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(cache.sizes, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(cache.sizes, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(cache.sizes[index]))
        }
    }

    private func arrangement(_ sizes: [CGSize], width: CGFloat?) -> MetricFlowArrangement {
        MetricFlowArrangement(sizes: sizes, proposedWidth: width,
                              horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
    }
}

/// Pure geometry shared by measurement and placement. Fixed-size metric views
/// keep their intrinsic size; an oversized metric gets its own row without
/// expanding a finite container proposal.
struct MetricFlowArrangement: Equatable {
    let size: CGSize
    let origins: [CGPoint]

    init(sizes: [CGSize], proposedWidth: CGFloat?, horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var rowHasItem = false
        var positions: [CGPoint] = []
        positions.reserveCapacity(sizes.count)

        for item in sizes {
            let rightEdge = x + item.width
            if rowHasItem, let width, Self.exceeds(rightEdge, width: width) {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
                rowHasItem = false
            }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + item.width)
            rowHeight = max(rowHeight, item.height)
            x += item.width + horizontalSpacing
            rowHasItem = true
        }

        // Returning usedWidth for a finite proposal lets a parent shrink the
        // placement bounds and ask for a different wrap/height on the next pass.
        // An unspecified/infinite probe instead reports a finite ideal size.
        self.size = CGSize(width: width ?? usedWidth, height: sizes.isEmpty ? 0 : y + rowHeight)
        self.origins = positions
    }

    private static func exceeds(_ edge: CGFloat, width: CGFloat) -> Bool {
        // Addition and parent placement may round the same row width differently.
        // Ignore only floating-point noise, not a visible reduction in available space.
        let tolerance = max(1, max(abs(edge), abs(width))) * CGFloat.ulpOfOne * 8
        return edge > width && edge - width > tolerance
    }
}
