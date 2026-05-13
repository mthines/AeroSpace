public struct OverviewCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .overview,
        allowInConfig: true,
        help: overview_help_generated,
        flags: [
            "--suspend": trueBoolFlag(\.suspend),
            "--resume": trueBoolFlag(\.resume),
        ],
        posArgs: [],
    )

    public var suspend: Bool = false
    public var resume: Bool = false
}

func parseOverviewCmdArgs(_ args: StrArrSlice) -> ParsedCmd<OverviewCmdArgs> {
    parseSpecificCmdArgs(OverviewCmdArgs(rawArgs: args), args)
        .filter("--suspend and --resume are mutually exclusive") { !($0.suspend && $0.resume) }
}
