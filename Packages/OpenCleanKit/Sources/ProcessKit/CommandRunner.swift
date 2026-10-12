import Foundation

public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut(String)
}

/// Runs an executable directly (never through a shell) and captures its output.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

/// Serial queue for timeouts. Serial queues are overcommit, so the timer always fires even when
/// the global pool is saturated by threads blocked in `run`. (Concurrent queues, including private
/// ones, are not guaranteed a thread.) The stderr reader uses a dedicated `Thread` for the same reason.
private let timerQueue = DispatchQueue(label: "openclean.processkit.timer")

public struct ProcessCommandRunner: CommandRunner {
    let timeout: TimeInterval?

    /// `timeout` is in seconds; `nil` waits forever.
    public init(timeout: TimeInterval? = 60) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        let timedOut = Flag()
        var timer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { [process] in
                if process.isRunning {
                    timedOut.set()
                    process.terminate()
                }
            }
            timer = item
            timerQueue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        // Drain stderr on another thread so a full pipe buffer can never deadlock the child.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        let reader = Thread {
            stderrBox.set(stderrHandle.readDataToEndOfFile())
            group.leave()
        }
        reader.name = "openclean.processkit.stderr"
        reader.start()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer?.cancel()
        if timedOut.get() {
            throw CommandError.timedOut("\(executable) exceeded \(timeout ?? 0)s")
        }
        return CommandOutput(status: process.terminationStatus, stdout: stdoutData, stderr: stderrBox.get())
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    func get() -> Bool { lock.withLock { value } }
}
