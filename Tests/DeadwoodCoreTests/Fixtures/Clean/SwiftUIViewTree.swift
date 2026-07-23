// swift-format-ignore-file
// SwiftUI view tree: the App root, view bodies, wrapped state, and private
// subviews referenced from a body are all live.
import SwiftUI

@main
struct GardenApp: App {
    var body: some Scene {
        WindowGroup {
            GardenView()
        }
    }
}

struct GardenView: View {
    @State private var waterings = 0

    var body: some View {
        VStack {
            Text("waterings: \(waterings)")
            WaterButton {
                waterings += 1
            }
        }
    }
}

private struct WaterButton: View {
    let action: () -> Void

    var body: some View {
        Button("water", action: action)
    }
}
