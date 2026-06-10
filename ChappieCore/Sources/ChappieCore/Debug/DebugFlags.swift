import Foundation

/// Debug-only feature flags for testing license flows.
/// All flags are compiled out in Release builds via #if DEBUG.
#if DEBUG
public enum DebugFlags {

    /// When true — owner JWT is ignored during initialize().
    /// App behaves as a regular user: trial registration, activation flow, etc.
    /// Set to true to test trial/paywall/activation without touching Keychain.
    public static let ignoreOwnerLicense: Bool = true
}
#endif
