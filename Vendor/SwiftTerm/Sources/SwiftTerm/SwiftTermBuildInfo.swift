// Static replacement for the build-info plugin output (the vendored copy has no Git metadata).

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"
    public static let hasUncommittedChanges: Bool? = true
    public static let version: String = "v1.20.0-timeline"
}
