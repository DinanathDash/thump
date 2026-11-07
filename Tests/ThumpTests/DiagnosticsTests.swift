import Foundation
import Testing
@testable import Thump

@Suite("Diagnostics and Logging")
struct DiagnosticsTests {
    @Test("Logger records entries and flushes synchronously to disk")
    func loggingAndFlushing() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumpLogTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = ThumpLogger(directory: tempDir)
        logger.record(message: "Unit test diagnostic log line")
        logger.syncFlush()

        let logFile = tempDir.appendingPathComponent("thump.log")
        #expect(FileManager.default.fileExists(atPath: logFile.path))

        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(content.contains("[Thump] Unit test diagnostic log line"))
    }

    @Test("Logger rotates file when exceeding maximum configured file size")
    func logRotation() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumpRotateTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Configure a small maxFileSize of 250 bytes with 2 backups
        let logger = ThumpLogger(directory: tempDir, maxFileSize: 250, maxBackups: 2)

        // Write enough entries to force multiple rotations
        for i in 1...25 {
            logger.record(message: "Message payload item #\(i) padding padding padding")
        }
        logger.syncFlush()

        let fm = FileManager.default
        let mainLog = tempDir.appendingPathComponent("thump.log")
        let backup1 = tempDir.appendingPathComponent("thump.1.log")

        #expect(fm.fileExists(atPath: mainLog.path))
        #expect(fm.fileExists(atPath: backup1.path))
    }

    @Test("Log export creates a valid zip archive from log directory")
    func logExportCreatesZip() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumpExportTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = tempDir.appendingPathComponent("thump.log")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "2026-11-07 [Thump] Sample log entry for export\n".write(to: logFile, atomically: true, encoding: .utf8)

        let archiveURL = try await ThumpLogExporter.exportLogs(from: tempDir)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(archiveURL.pathExtension == "zip")

        let attrs = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        #expect(size > 0)
    }

    @Test("Log export creates an archive even when directory is newly initialized")
    func logExportOnFreshDirectory() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumpFreshExportTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = try await ThumpLogExporter.exportLogs(from: tempDir)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(archiveURL.pathExtension == "zip")
    }

    @Test("Concurrent logging from multiple threads is thread-safe")
    func concurrentLogging() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumpConcurrentTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = ThumpLogger(directory: tempDir)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            logger.record(message: "Concurrent log #\(i)")
        }
        logger.syncFlush()

        let logFile = tempDir.appendingPathComponent("thump.log")
        #expect(FileManager.default.fileExists(atPath: logFile.path))
    }
}
