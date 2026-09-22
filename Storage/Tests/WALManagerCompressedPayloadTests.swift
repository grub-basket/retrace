import Foundation
import XCTest
import Shared
@testable import Storage

/// Covers the compressed WAL payload format:
/// - a stored frame is compressed on disk and decodes back to tightly packed BGRA
/// - pre-existing raw BGRA records (legacy layout, identical header) read unchanged
/// - a record carrying the compressed signature that fails to decode is rejected
///   at the WAL boundary instead of being returned as an undersized "raw" frame
/// - when compression would not shrink a frame, it is stored raw (fallback)
final class WALManagerCompressedPayloadTests: XCTestCase {
    private var walRoot: URL!

    override func setUp() {
        super.setUp()
        walRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-compressed-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let walRoot {
            try? FileManager.default.removeItem(at: walRoot)
        }
        super.tearDown()
    }

    // MARK: - Compressed round-trip

    func testStoredFrameIsCompressedAndDecodesBackToBGRA() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 1))
        let frame = Self.makeGradientFrame(width: 64, height: 64, seed: 30)

        try await wal.appendFrame(frame, to: &session)

        let framesSize = try Self.fileSize(session.framesURL)
        XCTAssertGreaterThan(framesSize, 0)
        XCTAssertLessThan(
            framesSize,
            frame.imageData.count,
            "frames.bin should hold a compressed payload, not raw BGRA"
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.width, 64)
        XCTAssertEqual(read.height, 64)
        XCTAssertEqual(read.bytesPerRow, 64 * 4, "decoded frames are tightly packed")
        XCTAssertEqual(read.imageData.count, 64 * 4 * 64)
        XCTAssertEqual(read.metadata.appBundleID, frame.metadata.appBundleID)
        XCTAssertEqual(read.metadata.windowName, frame.metadata.windowName)
        Self.assertPixelsApproximatelyEqual(read, frame, tolerance: 16)
    }

    // MARK: - Backward compatibility

    func testLegacyRawRecordStillReadsUnchanged() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 2))

        // A raw record as written by the previous (uncompressed) implementation.
        // Deliberately padded bytesPerRow so we can prove the raw path preserves it.
        let width = 8, height = 4, bytesPerRow = 40
        let raw = Data((0..<(bytesPerRow * height)).map { UInt8($0 % 251) })
        try Self.writeRecord(
            to: session.framesURL,
            payload: raw,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, raw, "raw payload must be returned byte-for-byte")
        XCTAssertEqual(read.width, width)
        XCTAssertEqual(read.height, height)
        XCTAssertEqual(read.bytesPerRow, bytesPerRow, "raw path must preserve the original bytesPerRow")
    }

    // MARK: - Malformed records

    func testCorruptCompressedRecordIsRejected() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 3))

        // Carries the JPEG signature and is not raw-sized, but is not a decodable image.
        var corrupt = Data([0xFF, 0xD8, 0xFF])
        corrupt.append(Data(repeating: 0x5A, count: 97))
        try Self.writeRecord(
            to: session.framesURL,
            payload: corrupt,
            width: 64,
            height: 64,
            bytesPerRow: 64 * 4
        )

        do {
            _ = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
            XCTFail("a corrupt compressed record must be rejected, not returned as a raw frame")
        } catch {
            // expected: rejected at the WAL boundary
        }
    }

    func testDamagedJPEGMarkerIsRejectedInsteadOfReturnedAsRaw() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 5))
        let frame = Self.makeGradientFrame(width: 64, height: 64, seed: 30)
        try await wal.appendFrame(frame, to: &session)
        var record = try Data(contentsOf: session.framesURL)
        let metadataSize = [frame.metadata.appBundleID, frame.metadata.appName,
                            frame.metadata.windowName, frame.metadata.browserURL]
            .reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let payloadOffset = 36 + metadataSize
        XCTAssertEqual(Array(record[payloadOffset..<(payloadOffset + 3)]), [0xFF, 0xD8, 0xFF])
        record[payloadOffset] = 0 // Damage a real compressed record's signature.
        try record.write(to: session.framesURL)
        try await assertReadRejected(wal, videoID: session.videoID)
    }

    func testOverflowingRawSizeIsRejectedWithoutTrapping() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 6))
        try Self.writeRecord(
            to: session.framesURL,
            payload: Data([0xFF, 0xD8, 0xFF, 0]),
            width: 64,
            height: Int(UInt32.max),
            bytesPerRow: Int(UInt32.max)
        )
        try await assertReadRejected(wal, videoID: session.videoID)
    }

    func testCompressedDimensionsMustMatchWALHeader() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 7))
        try await wal.appendFrame(Self.makeGradientFrame(width: 64, height: 64, seed: 30), to: &session)
        var record = try Data(contentsOf: session.framesURL)
        let width = UInt32(32)
        withUnsafeBytes(of: width) { record.replaceSubrange(8..<12, with: $0) }
        try record.write(to: session.framesURL)
        try await assertReadRejected(wal, videoID: session.videoID)
    }

    private func assertReadRejected(_ wal: WALManager, videoID: VideoSegmentID) async throws {
        do {
            _ = try await wal.readFrame(videoID: videoID, frameIndex: 0)
            XCTFail("Corrupt WAL records must be rejected before returning raw pixels")
        } catch let error as StorageError {
            guard case .fileReadFailed = error else {
                XCTFail("Expected fileReadFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Fallback

    func testFrameThatDoesNotShrinkIsStoredRaw() async throws {
        let wal = WALManager(walRoot: walRoot, memoryBackedSessionsEnabled: false)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 4))
        // 8x8 raw is 256 bytes; a JPEG of it is larger, so the payload must stay raw.
        let frame = Self.makeGradientFrame(width: 8, height: 8, seed: 7)

        try await wal.appendFrame(frame, to: &session)

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, frame.imageData, "raw fallback must be byte-for-byte")
        XCTAssertEqual(read.bytesPerRow, frame.bytesPerRow)
    }

    // MARK: - Helpers

    /// Smooth BGRA gradient: compresses well with low JPEG error, and at 64x64
    /// (16KB raw) the JPEG is comfortably smaller than raw.
    private static func makeGradientFrame(width: Int, height: Int, seed: UInt8) -> CapturedFrame {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    base[offset] = UInt8(min(255, x * 4))     // B
                    base[offset + 1] = UInt8(min(255, y * 4)) // G
                    base[offset + 2] = seed                   // R
                    base[offset + 3] = 255                    // A
                }
            }
        }
        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowName: "Window \(seed)",
                browserURL: nil,
                displayID: 1
            )
        )
    }

    /// Compare B/G/R of every pixel within a tolerance (alpha ignored: JPEG has none).
    private static func assertPixelsApproximatelyEqual(
        _ actual: CapturedFrame,
        _ expected: CapturedFrame,
        tolerance: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        var maxDelta = 0
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                let a = y * actual.bytesPerRow + x * 4
                let e = y * expected.bytesPerRow + x * 4
                for channel in 0..<3 {
                    let delta = abs(Int(actual.imageData[a + channel]) - Int(expected.imageData[e + channel]))
                    maxDelta = max(maxDelta, delta)
                }
            }
        }
        XCTAssertLessThanOrEqual(
            maxDelta,
            tolerance,
            "decoded pixels drifted by up to \(maxDelta) (> \(tolerance))",
            file: file,
            line: line
        )
    }

    /// Writes one record in the on-disk layout: 36-byte header (native endianness,
    /// same field order as WALFrameHeader), no metadata strings, then the payload.
    /// dataSize is the payload length, so a raw-sized payload reads as raw and any
    /// other size is treated as compressed.
    private static func writeRecord(
        to framesURL: URL,
        payload: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        var record = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { record.append(contentsOf: $0) }
        }
        append(Double(1_700_000_000))   // timestamp
        append(UInt32(width))
        append(UInt32(height))
        append(UInt32(bytesPerRow))
        append(UInt32(payload.count))   // dataSize
        append(UInt32(1))               // displayID
        append(UInt16(0))               // appBundleIDLength
        append(UInt16(0))               // appNameLength
        append(UInt16(0))               // windowNameLength
        append(UInt16(0))               // browserURLLength
        XCTAssertEqual(record.count, 36, "header must be 36 bytes")
        record.append(payload)
        try record.write(to: framesURL)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
