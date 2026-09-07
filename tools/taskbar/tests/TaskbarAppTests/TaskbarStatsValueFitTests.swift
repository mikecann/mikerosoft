import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarStatsValueFitTests: XCTestCase {
    func testPercentagesFitCompactModulesWithoutLosingPercentSign() {
        for width in [StatsWidgetMetrics.minimumMemoryWidth, StatsWidgetMetrics.minimumGPUWidth, StatsWidgetMetrics.minimumCPUWidth] {
            for percent in 0...100 {
                let text = formattedStatsPercent(Double(percent))
                let available = width - StatsWidgetMetrics.sideLabelWidth - StatsWidgetMetrics.sideLabelGap
                let font = statsValueFont(for: text, width: available, preferredSize: 12)
                XCTAssertGreaterThanOrEqual(font.pointSize, 8)
                XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: font]).width, available)
            }
        }
    }

    func testNetworkValuesKeepDirectionAndUnitsAtCompactAndExpandedWidths() {
        for width in [StatsWidgetMetrics.minimumNetworkWidth, StatsWidgetMetrics.preferredNetworkWidth] {
            for rate in [0.0, 999, 1023.9, 263 * 1024, 1023.9 * 1024, 12_500_000_000] as [Double] {
                for arrow in ["↑", "↓"] {
                    let text = "\(arrow) \(formattedStatsBytesPerSecond(rate))"
                    let available = width - StatsWidgetMetrics.sideLabelWidth - StatsWidgetMetrics.sideLabelGap
                    let font = statsValueFont(for: text, width: available, preferredSize: 10)
                    XCTAssertGreaterThanOrEqual(font.pointSize, 8)
                    XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: font]).width, available)
                }
            }
        }
    }

    func testExpandedValuesKeepNormalFontSize() {
        XCTAssertEqual(statsValueFont(for: "79%", width: 60, preferredSize: 12).pointSize, 12)
    }
}
