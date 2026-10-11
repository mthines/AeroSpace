public struct OverviewCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .overview,
        help: overview_help_generated,
        flags: [
            "--windows": trueBoolFlag(\.windows),
            "--suspend": trueBoolFlag(\.suspend),
            "--resume": trueBoolFlag(\.resume),
        ],
        posArgs: [],
    )

    /// Show the focused workspace's windows (one cell per window) instead of workspaces.
    public var windows: Bool = false
    public var suspend: Bool = false
    public var resume: Bool = false
}

func parseOverviewCmdArgs(_ args: StrArrSlice) -> ParsedCmd<OverviewCmdArgs> {
    parseSpecificCmdArgs(OverviewCmdArgs(rawArgs: args), args)
        .filter("--suspend and --resume are mutually exclusive") { !($0.suspend && $0.resume) }
        .filter("--windows is incompatible with --suspend and --resume") { $0.windows.implies(!$0.suspend && !$0.resume) }
}
