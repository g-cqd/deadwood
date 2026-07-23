// swift-format-ignore-file
// Ported from SwiftStaticAnalysis UnusedCodeScenarios/IndirectReferences.
// Functions passed as values (arrays, dictionaries, callbacks, map
// arguments, typealias-typed lets) are referenced; only the genuinely
// orphaned declarations are findings.
import Foundation

/// Passed to an array below — used.
private func foo() { print("foo") }

/// Stored as a callback — used.
private func handleSuccess() { print("Success!") }

/// Stored in a dictionary — used.
private func processA() { print("Processing A") }
private func processB() { print("Processing B") }

// oracle:begin
private func bar() { print("bar") }  // #dw:expect unused-function

private func unusedHelper() { print("unused") }  // #dw:expect unused-function
// oracle:end

let functions: [() -> Void] = [foo]

let processors: [String: () -> Void] = [
    "A": processA,
    "B": processB,
]

class CallbackManager {
    init() {
        onSuccess = handleSuccess
    }

    var onSuccess: (() -> Void)?

    func execute() {
        onSuccess?()
    }
}

func executeAll() {
    for function in functions {
        function()
    }
    for processor in processors.values {
        processor()
    }
}

/// Used as a map argument — used.
private func transform(_ value: Int) -> Int {
    value * 2
}

// oracle:begin
private func unusedTransform(_ value: Int) -> Int {  // #dw:expect unused-function
    value * 3
}
// oracle:end

let numbers = [1, 2, 3, 4, 5]
let doubled = numbers.map(transform)

private func optionalHandler() { print("optional") }

var optionalCallback: (() -> Void)?

func setupOptionalCallback() {
    optionalCallback = optionalHandler
}

typealias Handler = () -> Void

private func aliasedHandler() { print("aliased") }

let handlerRef: Handler = aliasedHandler

// oracle:begin
private func neverCalled1() { print("never1") }  // #dw:expect unused-function
private func neverCalled2() { print("never2") }  // #dw:expect unused-function
private func neverCalled3() { print("never3") }  // #dw:expect unused-function

private var unusedVariable = 42  // #dw:expect unused-property
private let unusedConstant = "unused"  // #dw:expect unused-property

private class UnusedClass {  // #dw:expect unused-type
    func unusedMethod() {}
}
// oracle:end
