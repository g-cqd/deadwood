//  SCARF grep-demotion: the class is named ONLY inside a string literal
//  (NSClassFromString-style dynamic lookup). Static analysis cannot prove
//  the dynamic reference, so the finding still FIRES — demoted to low
//  confidence with a dynamic-reference note (asserted by ConfidenceTests).

import Foundation

// oracle:begin
private final class LegacyMigrator {  // #dw:expect unused-type
    func migrate() {}
}
// oracle:end

public func loadMigratorClass() -> AnyClass? {
    NSClassFromString("LegacyMigrator")
}
