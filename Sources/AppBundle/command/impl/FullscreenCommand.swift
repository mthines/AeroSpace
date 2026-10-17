import AppKit
import Common

struct FullscreenCommand: Command {
    let args: FullscreenCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        // In the windows overview, toggling means "fullscreen the window I picked": close the
        // grid on the highlighted window, then turn fullscreen on for it.
        var closedOverview = false
        if args.windowId == nil && env.windowId == nil && args.toggle != .off {
            closedOverview = (try? await OverviewManager.shared.closeWindowsModeOnSelection()) ?? false
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: closedOverview || !window.isFullscreen
        }
        if closedOverview && window.isFullscreen { return .succ }
        if newState == window.isFullscreen {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already fullscreen. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not fullscreen. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        window.isFullscreen = newState
        window.noOuterGapsInFullscreen = args.noOuterGaps

        // Focus on its own workspace
        window.markAsMostRecentChild()
        return .succ
    }
}

let noWindowIsFocused = "No window is focused"
