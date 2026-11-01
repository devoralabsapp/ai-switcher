import SwiftUI

/// Keep reading order stable while each column follows its own card heights.
struct AccountColumnsLayout: Layout {
    var minimumWidth: CGFloat = 245
    var spacing: CGFloat = 16

    private func geometry(width: CGFloat, subviews: Subviews) -> (CGSize, [CGRect]) {
        // SwiftUI also probes zero and infinite proposals before actual placement.
        let width = width.isFinite ? max(0, width) : minimumWidth
        let columns = max(1, Int(min(CGFloat(max(1, subviews.count)), (width + spacing) / (minimumWidth + spacing))))
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights = Array(repeating: CGFloat.zero, count: columns)
        var frames: [CGRect] = []
        for (index, view) in subviews.enumerated() {
            let column = index % columns
            let size = view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil))
            frames.append(CGRect(x: CGFloat(column) * (cardWidth + spacing), y: heights[column], width: cardWidth, height: size.height))
            heights[column] += size.height + spacing
        }
        return (CGSize(width: width, height: max(0, (heights.max() ?? 0) - spacing)), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        geometry(width: proposal.width ?? minimumWidth, subviews: subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = geometry(width: bounds.width, subviews: subviews).1
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
