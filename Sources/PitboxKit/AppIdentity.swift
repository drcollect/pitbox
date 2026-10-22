import Foundation

/// The product's identity. Use `displayName` for every name a person sees (menus, windows, sheets, tags, notices), so
/// a fork renames the app in one place.
public enum AppIdentity {
    public static let displayName = "Pitbox"
    /// The default bundle identifier. A build may set its own (`PITBOX_BUNDLE_ID` in `scripts/build.sh`); code that
    /// needs the running app's id reads `Bundle.main.bundleIdentifier` and falls back to this.
    public static let defaultBundleID = "io.github.drcollect.pitbox"
    /// The running app's bundle identifier, or `defaultBundleID` outside an app bundle (tests, tools).
    public static var bundleID: String { Bundle.main.bundleIdentifier ?? defaultBundleID }
}
