import AppKit
import Common

struct OverviewCommand: Command {
    let args: OverviewCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do {
            if args.suspend {
                try await OverviewManager.shared.suspend()
            } else if args.resume {
                try await OverviewManager.shared.resume()
            } else {
                let mode: OverviewMode = args.windows ? .windows(workspaceName: focus.workspace.name) : .workspaces
                try await OverviewManager.shared.activate(mode: mode)
            }
        } catch {
            return .fail(io.err(bugPrompt(String(describing: error))))
        }
        return .succ
    }
}
