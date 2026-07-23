// swift-format-ignore-file
// A case never constructed and never matched (in a non-raw, non-Codable
// enum) is dead surface for every switch over the enum.
private enum Route {
    case home
    case settings
    // oracle:begin
    case debugMenu  // #dw:expect unused-enum-case
    // oracle:end
}

func destination(_ tab: Int) -> Route {
    tab == 0 ? .home : .settings
}

func label(_ route: Route) -> String {
    switch route {
    case .home: "home"
    case .settings: "settings"
    default: "hidden"
    }
}
