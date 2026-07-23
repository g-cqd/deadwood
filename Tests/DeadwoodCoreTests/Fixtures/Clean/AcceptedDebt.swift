// swift-format-ignore-file
// Suppression: an accepted finding leaves the findings list (and lands in
// the suppressed list instead), with its reason on record.
func keepalive() -> Int { 7 }

// @dw:accept unused-function -- kept for the v2 API
private func futureEntryPoint() -> Int { keepalive() }
