# Rules

`deadwood rules` lists them and `deadwood rules <id>` explains one. A rule is judged across every file you pass: a declaration is unused when nothing reachable from an entry point refers to it. Analyzing one file alone judges only what is private to that file.

| rule | default | finds |
| --- | --- | --- |
| `unused-function` | on | functions/methods unreachable from any entry point |
| `unused-type` | on | types nothing references (members collapse into the type) |
| `unused-property` | on | stored/computed properties with no reference |
| `unused-enum-case` | on | cases never constructed or matched (raw-value/Codable/CaseIterable enums exempt, including conformances added via extension) |
| `unused-transitively` | on | declarations only dead code uses, reported in the same run as the dead code, grouped under it and naming its dead users (confidence: the weakest along the chain) |
| `dead-branch` | on | branches whose condition provably folds to a constant |
| `referenced-only-by-tests` | on (fires only under `--production`) | declarations reachable with test roots but unreachable without them |
| `preview-only` | on, note | production code only `#Preview` bodies and `PreviewProvider` types use: it ships in release builds for nothing |
| `debug-only` | on, note | production code only `#if DEBUG` code uses: it ships in release builds for nothing |
| `unused-import` | off | imports with no referenced symbol in the file (syntax-level heuristic; `@_exported` is never flagged) |
| `unused-public-api` | off | public declarations unreferenced inside the corpus (public API is a root otherwise) |
| `assign-only-property` | off | stored properties whose every reference is a write |
| `dead-store` | off | assignments overwritten before any read (liveness + reaching definitions) |

## Entry points

Reachability starts from the roots below. A root is never reported, and
everything it uses stays used. 
**Swift declarations**

- `@main`, `@UIApplicationMain`, `@NSApplicationMain`; a `main` function; a
  static `main()`.
- Public and open declarations, unless `unused-public-api` is enabled, which
  judges them like internal ones.
- `@objc` and `@objcMembers`, including KVO-observed `@objc dynamic`
  properties (on by default, `treatObjcAsRoot`). A `dynamic` member without
  `@objc` is not a root.
- Interface Builder attributes: `@IBAction`, `@IBOutlet`, `@IBInspectable`,
  `@IBDesignable`, `@IBSegueAction`.
- Codable and raw-value requirements: a `CodingKeys` enum, stored properties of
  a type conforming to `Codable`, `Encodable` or `Decodable`, and cases of
  raw-value or `CaseIterable` enums, which other code constructs.
- `@dynamicMemberLookup` and `@dynamicCallable` types.
- Operator functions; `@resultBuilder` members; `wrappedValue` and
  `projectedValue` of property wrappers; `@_silgen_name`, `@_cdecl`,
  `@_dynamicReplacement`, `@_objcRuntimeName`.
- Overrides of a superclass member.
- Protocol witnesses of a protocol or superclass declared outside the
  analyzed files. A member whose name a cataloged protocol requires is kept
  (`Equatable`, `Hashable`, `Codable`, `CustomStringConvertible`,
  `Identifiable`, `Sequence`, SwiftUI `View`, ArgumentParser, and others). A
  type conforming to an uncataloged external type, such as `UIResponder`,
  `NSManagedObject` or `UIWindowSceneDelegate`, keeps all its non-private
  members. `@NSManaged` members are kept at any access level, `private`
  included, because Core Data reaches them by name at runtime.
- What a type conforms to is read through your own protocols and superclasses:
  `struct User: Entity` with `protocol Entity: Hashable` conforms to `Hashable`,
  so its `hash(into:)` is a witness, and a type of `protocol Shape:
  CustomStringConvertible` keeps its `description`. A superclass declared in the
  analyzed files is not an unknown external type: it exempts none of its
  subclass's members, only what it itself inherits does. Only a protocol or a
  class counts as a base, so a nested `enum Layout` does not hide SwiftUI's
  `Layout`.
- With an index store, the compiler's own record is added: a member it says
  overrides or witnesses a requirement defined outside the analyzed files is kept,
  whatever its name and wherever the conformance is written
  ([index store](index-store.md#how-the-index-is-read)).
- SwiftUI `App` and `View` types, `body`, `PreviewProvider`, and SwiftUI
  property wrappers; App Intents, App Shortcuts and Widget conformers.
- Test code: functions named `test…` or annotated `@Test`; `@Suite` types,
  types holding `@Test` functions, and `XCTestCase` subclasses, at any depth.
- File-scope code: top-level statements and `#Preview` bodies.
- Everything in a generated file: one whose header names a generator ("Generated using", "@generated", "DO NOT EDIT") or that sits in a `Generated` directory. Nothing in it is reported.

**Project files**

The types a project file names are roots, matched by their name without the
module prefix (`$(PRODUCT_MODULE_NAME).SceneDelegate` becomes `SceneDelegate`).
Only classes, structs, enums and actors match.

- Info.plist keys at any nesting depth: `NSExtensionPrincipalClass`,
  `NSPrincipalClass`, `UISceneDelegateClassName`, `UISceneClassName`,
  `WKExtensionDelegateClassName`, `WKApplicationDelegateClassName`,
  `CLKComplicationPrincipalClass`.
- `INFOPLIST_KEY_<key>` build settings in `project.pbxproj`, with the same keys.
- `customClass` attributes in storyboards and xibs.

A scene or app delegate that nothing names (no plist key, no build setting,
no code reference) is reported as an unused type. A delegate that code names,
such as `config.delegateClass = SceneDelegate.self` in the app delegate, is
kept.

## Confidence model

Every finding's note carries its confidence, and the same level is a structured `confidence` field in the JSON report and SARIF `properties.confidence`. The levels:

- **certain** — dataflow proofs on literal conditions (`if false`); a dead
  branch proven by propagating a variable is **high**.
- **high / medium / low** — by *effective* visibility: private/fileprivate
  high, internal medium, package/public/open low (a member of a private
  type is effectively private).
- **Demotions** for dynamic-reference risk: a name appearing inside a
  string literal outside the declaration itself and outside generated files
  (NSClassFromString-style lookup) forces low with a note; members of
  NSObject subclasses without `@objc` demote one step (selector machinery may
  reach them). Demoted findings still fire — risk lowers confidence, it
  never hides dead code.
- A name that a comment still mentions, as commented-out code does, adds a
  note but never lowers the confidence.
