//  StringTrimming.swift
//  deadwood
//
//  The handful of `String` conveniences deadwood uses that live in corelibs
//  Foundation rather than FoundationEssentials — reimplemented on the standard
//  library so the Linux binary does not have to link Foundation, and with it
//  ~51 MiB of ICU (see the FoundationEssentials migration commit).
//
//  Deliberately *not* named after their Foundation counterparts: the Core ML
//  files still import Foundation, and same-name extensions would shadow
//  ambiguously there.

extension String {
    /// Equivalent of `trimmingCharacters(in: .whitespaces)`.
    ///
    /// `CharacterSet.whitespaces` is spaces and horizontal tabs; the standard
    /// library's `Character.isWhitespace` also covers newlines, so this trims
    /// on the narrower predicate to preserve the original behaviour exactly.
    var trimmedHorizontalWhitespace: String {
        let isHorizontal: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        return String(
            self.drop(while: isHorizontal).reversed().drop(while: isHorizontal).reversed()
        )
    }

    /// Equivalent of `trimmingCharacters(in: .whitespacesAndNewlines)`.
    var trimmedWhitespaceAndNewlines: String {
        String(
            self.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
        )
    }

    /// Equivalent of `replacingOccurrences(of:with:)` for literal targets.
    func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        return self.replacing(target, with: replacement)
    }
}
