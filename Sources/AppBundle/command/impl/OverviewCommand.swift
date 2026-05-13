import AppKit
import Common

struct OverviewCommand: Command {
    let args: OverviewCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        if args.suspend {
            try await OverviewManager.shared.suspend()
        } else if args.resume {
            try await OverviewManager.shared.resume()
        } else {
            try await OverviewManager.shared.activate()
        }
        return .succ
    }
}
