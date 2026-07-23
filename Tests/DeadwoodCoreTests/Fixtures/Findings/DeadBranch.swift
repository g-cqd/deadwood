// swift-format-ignore-file
// Branches whose condition provably folds to a constant never execute.
// The code inside reads as if it runs — that is the bug.
func selectPath(_ input: Int) -> Int {
    if false {  // #dw:expect dead-branch
        return -1
    }
    return input
}

func gatedFeature() -> String {
    let enabled = false
    if enabled {  // #dw:expect dead-branch
        return "on"
    }
    return "off"
}

func alwaysTaken() -> Int {
    var total = 0
    if true {  // #dw:expect dead-branch
        total += 1
    } else {
        total -= 1
    }
    return total
}
