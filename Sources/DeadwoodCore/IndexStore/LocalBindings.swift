/// The names that a stretch of Swift source binds itself: locals, pattern variables, closure parameters, loop variables and the
/// names the language supplies. The syntax facts declare parameters and some locals but not an optional binding
/// (`guard let device = …`), a `case let` pattern or a closure's parameters, and the index records no use of any local. A name
/// bound here that is also a member's name (`device`) is the local wherever the source writes it bare, so it is not a use of the
/// member the index could have lost.
///
/// This reads text, not a syntax tree, and errs towards finding a binding: a name bound in one place and used as a member in
/// another of the same declaration is taken as bound. What that costs is a use that is not recovered, never one that is invented.
enum LocalBindings {
    /// The bound names in `text`.
    static func names(in text: String) -> Set<String> {
        var names = Set<String>()
        func add(_ list: Substring) {
            for part in list.split(separator: ",") {
                var piece = trimmed(part)
                if let colon = piece.firstIndex(of: ":") {
                    // `external internal: Type` (a parameter) binds `internal`; `label: let name` (a pattern) binds `name`.
                    let head = trimmed(piece[..<colon])
                    let tail = trimmed(piece[piece.index(after: colon)...])
                    piece =
                        tail.hasPrefix("let ") || tail.hasPrefix("var ")
                        ? tail : (head.split(separator: " ").last ?? head)
                }
                for word in piece.split(whereSeparator: { !isIdentifierCharacter($0) }) {
                    let name = String(word)
                    if name != "let", name != "var", name != "_", isIdentifier(name) { names.insert(name) }
                }
            }
        }
        for match in text.matches(of: singleBinding) { names.insert(String(match.output.1)) }
        for match in text.matches(of: tupleBinding) { add(match.output.1) }
        for match in text.matches(of: casePattern) { add(match.output.1) }
        for match in text.matches(of: closureParameters) {
            if let list = match.output.1 { add(list) }
            if let list = match.output.2 { add(list) }
        }
        for match in text.matches(of: loopVariable) {
            if let list = match.output.1 { add(list) }
            if let list = match.output.2 { add(list) }
        }
        if text.contains("catch") { names.insert("error") }
        if text.contains("didSet") { names.insert("oldValue") }
        if text.contains("willSet") || text.contains("set {") || text.contains("set(") { names.insert("newValue") }
        return names
    }

    // `let x`, `var x`, `if let x`, `guard let x`, `case let x`.
    private static var singleBinding: Regex<(Substring, Substring)> { #/\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/# }
    // `let (a, b)`.
    private static var tupleBinding: Regex<(Substring, Substring)> { #/\b(?:let|var)\s*\(([^()]*)\)/# }
    // `case let .found(a, b)`: the bindings follow the pattern.
    private static var casePattern: Regex<(Substring, Substring)> {
        #/\b(?:let|var)\s+\.?[A-Za-z_][A-Za-z0-9_.]*\(([^()]*)\)/#
    }
    // `{ a, b in`, `{ [weak self] (a, b) in`.
    private static var closureParameters: Regex<(Substring, Substring?, Substring?)> {
        #/\{\s*(?:\[[^\]]*\]\s*)?(?:\(([^()]*)\)|([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*))\s*(?:->\s*[^{}]*?)?\s+in\b/#
    }
    // `for x in`, `for (a, b) in`, `for case let x in`.
    private static var loopVariable: Regex<(Substring, Substring?, Substring?)> {
        #/\bfor\s+(?:case\s+)?(?:let\s+|var\s+)?(?:\(([^()]*)\)|([A-Za-z_][A-Za-z0-9_]*))\s+in\b/#
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var result = text.drop(while: \.isWhitespace)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isIdentifier(_ text: some StringProtocol) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy(isIdentifierCharacter)
    }
}
