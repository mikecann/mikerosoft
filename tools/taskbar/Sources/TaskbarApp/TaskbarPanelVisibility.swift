enum TaskbarSetShownAction: Equatable {
    case animate
    case snap
    case nothing
}

func taskbarSetShownAction(
    targetShown: Bool,
    currentShown: Bool,
    frameMatchesTarget: Bool,
    animatedRequested: Bool
) -> TaskbarSetShownAction {
    guard !frameMatchesTarget else { return .nothing }
    if targetShown != currentShown {
        return animatedRequested ? .animate : .snap
    }
    return animatedRequested ? .nothing : .snap
}
