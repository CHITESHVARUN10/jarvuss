import Foundation

extension Process {
    /// `waitUntilExit()` with a deadline. A child that is itself waiting on a
    /// user decision — the classic case being `osascript -e 'tell app "X" to
    /// quit'` when X pops a "terminate running processes?" confirmation —
    /// blocks forever, and a forever-blocked action is what left the command
    /// pipeline stuck on "Working". On timeout the process is terminated.
    ///
    /// - Returns: true when the process exited on its own before the deadline.
    @discardableResult
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning {
            if Date() >= deadline {
                terminate()
                // Give termination a moment to land; SIGKILL if it refuses.
                let killDeadline = Date().addingTimeInterval(2)
                while isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if isRunning {
                    kill(processIdentifier, SIGKILL)
                }
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}
