import Foundation
import StickerizeKit
import XCTest

/// The `stickerize` CLI under signals, run as a separate process: it must stop cleanly (dying of the signal, its
/// temporary files gone) even when its terminal or stderr is already gone, and keep signals it inherited as ignored.
final class CLISignalTests: XCTestCase {
    private var root: URL!
    private var input: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("stickerize isn't built next to the tests") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-signal-\(UUID().uuidString)", isDirectory: true)
        input = root.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let png = try noisePNG(side: 24)
        for index in 0..<400 { try png.write(to: input.appendingPathComponent(String(format: "%03d.png", index))) }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCtrlCStopsCleanly() throws {
        let process = try start(output: "out")
        let staging = try waitForStaging(of: process)
        kill(process.processIdentifier, SIGINT)
        try waitForExit(of: process)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGINT)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path), [])
    }

    /// A closed terminal: writing the "stopping" message fails, which mustn't crash the cleanup.
    func testStopsCleanlyWithStderrClosed() throws {
        let errors = Pipe()
        let process = try start(output: "out", stderr: errors)
        let staging = try waitForStaging(of: process)
        try errors.fileHandleForReading.close()
        kill(process.processIdentifier, SIGTERM)
        try waitForExit(of: process)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM, "died of the signal, not of a crash or SIGPIPE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// Closing a terminal that runs zsh sends the job two hangups about a millisecond apart: the second mustn't kill
    /// the run before it has cleaned up.
    func testTwoHangupsFromAClosedTerminal() throws {
        let process = try start(output: "out")
        let staging = try waitForStaging(of: process)
        kill(process.processIdentifier, SIGHUP)
        usleep(1000)
        kill(process.processIdentifier, SIGHUP)
        try waitForExit(of: process)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGHUP)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// A signal while the packs are being installed: they all land, the report is printed, then the process dies of
    /// the signal (so a calling script stops).
    func testASignalWhileInstallingLetsTheRunFinishAndReport() throws {
        for index in 30..<400 { try FileManager.default.removeItem(at: input.appendingPathComponent(String(format: "%03d.png", index))) }
        let hold = root.appendingPathComponent("hold")
        let stdout = root.appendingPathComponent("stdout.txt"), stderr = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["signal-pack", input.path, "--output", root.appendingPathComponent("out").path, "--max-per-pack", "1"]
        process.environment = ProcessInfo.processInfo.environment.merging(["STICKERIZE_TEST_HOLD_INSTALL": hold.path]) { $1 }
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 60)
        while !FileManager.default.fileExists(atPath: hold.path), process.isRunning, Date() < deadline { usleep(5000) }
        guard FileManager.default.fileExists(atPath: hold.path) else {
            process.terminate()
            return XCTFail("the run didn't reach installing")
        }
        kill(process.processIdentifier, SIGINT)
        usleep(200_000) // the handler runs
        try FileManager.default.removeItem(at: hold)
        try waitForExit(of: process)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGINT)
        let packs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path)
        XCTAssertEqual(packs.count, 30)
        XCTAssertEqual(try String(contentsOf: stdout, encoding: .utf8).split(separator: "\n").count, 30, "every pack listed")
        XCTAssertTrue(try String(contentsOf: stderr, encoding: .utf8).contains("interrupted after the packs were installed"))
    }

    /// `nohup` and background jobs of scripts start with SIGHUP or SIGINT ignored.
    func testInheritedIgnoredSignalsStayIgnored() throws {
        // Fewer images, to let the run finish.
        for index in 40..<400 { try FileManager.default.removeItem(at: input.appendingPathComponent(String(format: "%03d.png", index))) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' HUP; exec \"$0\" signal-pack \"$1\" --output \"$2\"", binary.path, input.path,
                             root.appendingPathComponent("out").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try waitForStaging(of: process)
        kill(process.processIdentifier, SIGHUP)
        try waitForExit(of: process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path), ["pack-01"])
    }

    // MARK: Helpers

    private var binary: URL {
        let products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
        return (products ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("stickerize")
    }

    private func start(output: String, stderr: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["signal-pack", input.path, "--output", root.appendingPathComponent(output).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr ?? FileHandle.nullDevice
        try process.run()
        return process
    }

    /// The run's staging folder, found by the process ID it records, once it holds a pack.
    private func waitForStaging(of process: Process) throws -> URL {
        let probe = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        try? FileManager.default.removeItem(at: probe)
        let parent = probe.deletingLastPathComponent()
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline, process.isRunning {
            for folder in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                let marker = try? String(contentsOf: folder.appendingPathComponent(".signal-pack-run"), encoding: .utf8)
                if marker == String(process.processIdentifier),
                   FileManager.default.fileExists(atPath: folder.appendingPathComponent("pack-01").path) {
                    return folder
                }
            }
            usleep(5000)
        }
        if process.isRunning {
            process.terminate()
            throw XCTSkip("the run didn't get to its first pack in time")
        }
        // Finishing that fast is a skip; crashing or failing is a failure.
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            XCTFail("the run ended early: \(process.terminationReason == .exit ? "exit" : "signal") \(process.terminationStatus)")
            throw CancellationError()
        }
        throw XCTSkip("the run finished before it could be interrupted")
    }

    /// Stopping must not take long: the run checks between files.
    private func waitForExit(of process: Process, within seconds: TimeInterval = 20) throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            XCTFail("still running \(Int(seconds)) s after the signal")
        }
        process.waitUntilExit()
    }

    private func noisePNG(side: Int) throws -> Data {
        var state: UInt64 = 99
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in pixels.indices {
            state = state &* 6364136223846793005 &+ 1
            pixels[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 40)
        }
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return try StickerEncoder.pngData(context.makeImage()!)
    }
}
