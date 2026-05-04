public struct OverviewCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .overview,
        allowInConfig: true,
        help: overview_help_generated,
        flags: [:],
        posArgs: [],
    )
}
