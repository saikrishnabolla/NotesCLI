import Foundation

package enum MCPRunLoopWaiter {
    package static func wait(for stopped: DispatchSemaphore) {
        precondition(Thread.isMainThread, "The MCP transport must keep the main run loop available.")
        while stopped.wait(timeout: .now()) != .success {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
