import Foundation
import QuartzCore

enum TaskbarSelectionAnimation {
    static let duration: TimeInterval = 0.22

    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.18, 0.88, 0.28, 1.0)
    }
}
