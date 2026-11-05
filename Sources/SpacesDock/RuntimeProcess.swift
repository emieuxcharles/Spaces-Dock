import Foundation

enum RuntimeProcessError: Error { case timedOut }

func runRuntimeProcess(_ process: Process, timeout: TimeInterval) throws -> Int32 {
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    defer { process.terminationHandler = nil }
    try process.run()
    guard completion.wait(timeout: .now() + timeout) == .success else {
        if process.isRunning { process.terminate() }
        throw RuntimeProcessError.timedOut
    }
    return process.terminationStatus
}
