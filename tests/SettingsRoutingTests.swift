import Foundation

@main
struct SettingsRoutingTests {
    static func main() {
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) == .swiftUI,
            "macOS 14 and newer must use SwiftUI's settings presentation action"
        )
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)) == .legacySelector("showSettingsWindow:"),
            "macOS 13 must use the Settings scene selector"
        )
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)) == .legacySelector("showPreferencesWindow:"),
            "macOS 12 and older must use the Preferences scene selector"
        )
        print("Settings routing tests passed")
    }
}
