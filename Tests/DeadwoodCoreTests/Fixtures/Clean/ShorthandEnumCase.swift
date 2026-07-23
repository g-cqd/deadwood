// swift-format-ignore-file
// Enum cases constructed via shorthand `.caseName` and matched in switch
// patterns count as references.
private enum Mode {
    case fast
    case careful
}

func pick(_ hurry: Bool) -> Int {
    let mode: Mode = hurry ? .fast : .careful
    switch mode {
    case .fast: return 1
    case .careful: return 2
    }
}
