# deadwood

Finds code that nothing uses: unreferenced functions, types, properties and enum cases, and branches whose condition can never
change. It reads Swift source with [swift-syntax](https://github.com/swiftlang/swift-syntax), so it works without a build, and it
gets more precise with the compiler's index.

```swift
struct Cache {
    func evict() {}      // unused-function: nothing calls it
    var hits = 0         // unused-property: nothing reads it

    func lookup(_ key: String) -> Int? {
        if false {       // dead-branch: the condition is a constant
            return nil
        }
        return nil
    }
}

@main
struct App {
    static func main() {
        _ = Cache().lookup("a")
    }
}
```

## What it finds

- **Unused declarations:** functions, types, properties and enum cases that no entry point reaches, and declarations only other
  dead code uses.
- **Dead branches** whose condition folds to a constant, and, as opt-in rules, dead stores and assign-only properties.
- **Code that ships for nothing:** production code that only previews or `#if DEBUG` code use, and, in production mode, code only
  tests use.

Entry points are found for you: `@main`, public API, `@objc`, Interface Builder, SwiftUI, App Intents, widgets, tests, and the
classes that Info.plists and storyboards name. Each finding says how sure it is (`certain`, `high`, `medium` or `low`), so a
review can start with the surest. [Rules](docs/rules.md) has the full list.

## Install

Download an archive from the [releases](https://github.com/g-cqd/deadwood/releases), or build with Swift 6.4 on macOS 15 or later,
or Linux:

```sh
swift build -c release
cp .build/release/deadwood /usr/local/bin/
```

## Use

```sh
deadwood analyze Sources Tests                     # include tests: they use production code
deadwood analyze . --index-store-path <store>      # compiler-precise (macOS); the best setup for Xcode projects
deadwood analyze --production Sources Tests        # report code only tests reach
deadwood analyze --format sarif .                  # for GitHub code scanning
```

Without an index, findings come from names, so review them rather than deleting blindly.

## Learn more

[User guide](docs/README.md): getting started, rules, configuration, CI, reports, the index store.

deadwood is one of a family of analyzers with the same options and reports:
[arcleak](https://github.com/g-cqd/arcleak) (leaks), [dolly](https://github.com/g-cqd/dolly) (duplicated code),
[fcheck](https://github.com/g-cqd/fcheck) and [modeler](https://github.com/g-cqd/modeler).

[MIT](LICENSE)
