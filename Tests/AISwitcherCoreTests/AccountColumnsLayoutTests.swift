import AppKit
import SwiftUI
import XCTest
@testable import AISwitcher

final class AccountColumnsLayoutTests: XCTestCase {
    @MainActor func testHostingSizeProbesAndResponsivePlacementStayFinite() {
        let content = AccountColumnsLayout {
            ForEach(Array([100.0, 340, 80, 120, 60].enumerated()), id: \.offset) { _, height in
                Color.clear.frame(height: height)
            }
        }
        let hosting = NSHostingView(rootView: content)
        // fittingSize exercises SwiftUI's unbounded proposal as well as actual widths.
        XCTAssertTrue(hosting.fittingSize.height.isFinite)
        for (width, expectedHeight) in [(245.0, 764.0), (780, 416), (1120, 340)] {
            let size = NSHostingView(rootView: content.frame(width: width)).fittingSize
            XCTAssertTrue(size.width.isFinite)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertEqual(size.height, expectedHeight, accuracy: 0.1)
        }
    }
    @MainActor func testFewCardsKeepCompactWidthAndNarrowWindowsStillFit() {
        for count in [1, 2] {
            for (width, expectedHeight) in [(200.0, Double(count) * 200 + Double(count - 1) * 16), (1120, 320)] {
                let content = AccountColumnsLayout {
                    ForEach(0..<count, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                }.frame(width: width)
                let size = NSHostingView(rootView: content).fittingSize
                XCTAssertEqual(size.height, expectedHeight, accuracy: 0.1)
                XCTAssertTrue(size.width.isFinite)
            }
        }
    }

}
