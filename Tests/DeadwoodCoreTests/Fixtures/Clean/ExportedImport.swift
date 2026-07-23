//  @_exported import re-exports the module to every client: the import IS
//  the usage. The unused-import rule must never flag it — pinned by a unit
//  test with the rule enabled; under defaults the rule is off.

@_exported import Foundation

@main
struct ExportedImportMain {
    static func main() {}
}
