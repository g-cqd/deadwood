// swift-format-ignore-file
// The empty program: the analyzer must stay silent on unremarkable code.
// The oracle fences below mark a REFERENCED declaration — the removal
// oracle uses this file as its control: deleting Point must break the
// typecheck, proving the oracle can actually detect a bad removal.
// oracle:begin
struct Point {
    var x: Int
    var y: Int
}
// oracle:end

func distanceSquared(_ a: Point, _ b: Point) -> Int {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy
}
