//  Production-mode fixture pair (analyzed together with HelpersTests.swift
//  as a two-file corpus): `onlyTestedHelper` is reachable ONLY from the
//  test file. Default mode keeps it alive (tests are roots); production
//  mode reports it as referenced-only-by-tests. `usedHelper` is production-
//  reachable; `deadHelper` is unreachable in both modes.

func usedHelper() -> Int { 3 }

func onlyTestedHelper() -> Int { 7 }

private func deadHelper() -> Int { 11 }

@main
struct ProductionMain {
    static func main() {
        _ = usedHelper()
    }
}
