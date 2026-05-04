import AppKit
import Common

struct OverviewCommand: Command {
    let args: OverviewCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        try await OverviewManager.shared.activate()
        return .succ
    }
}
