import Foundation
import AVFoundation
import CoreMedia

/// H264VideoLayer encapsulates H264 parsing, format-description management,
/// and enqueueing into an AVSampleBufferDisplayLayer.
final class H264VideoLayer {
    private var _displayLayer: AVSampleBufferDisplayLayer?
    var displayLayer: AVSampleBufferDisplayLayer {
        if let layer = _displayLayer {
            return layer
        }
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        _displayLayer = layer
        return layer
    }

    var onVideoDimensions: ((Int, Int) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var previousWasAnnexB: Bool?
    private let decodeQueue = DispatchQueue(label: "com.harmonymirror.h264video", qos: .userInitiated)
    private var decodeCount = 0
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var firstPts: Int64?

    init() {}

    /// Bind to an externally-managed AVSampleBufferDisplayLayer (e.g. from VideoPlayerView).
    func bind(displayLayer: AVSampleBufferDisplayLayer) {
        self._displayLayer = displayLayer
    }

    /// Feed raw H264 data (AnnexB or AVCC) into the pipeline.
    nonisolated func feed(_ data: Data, pts: Int64, isKeyFrame: Bool) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.process(data, pts: pts)
        }
    }

    /// Flush the display layer (e.g. after a seek or format change).
    func flush() {
        displayLayer.flush()
    }

    /// Remove all enqueued samples and flush.
    func flushAndRemoveImage() {
        displayLayer.flushAndRemoveImage()
    }

    // MARK: - Private

    nonisolated private func process(_ data: Data, pts: Int64) {
        decodeCount += 1
        if decodeCount <= 5 {
            Log.mirror.info("H264VideoLayer input #\(self.decodeCount), bytes=\(data.count)")
        }

        // Defensive cap to prevent memory pressure from corrupted streams
        let maxFrameBytes = 2 * 1024 * 1024
        guard data.count > 4, data.count <= maxFrameBytes else {
            if decodeCount <= 5 {
                Log.mirror.warning("H264VideoLayer input #\(self.decodeCount) too short or too large (\(data.count)), skipping")
            }
            return
        }

        let isAnnexB = detectAnnexB(data)
        if let prev = previousWasAnnexB, prev != isAnnexB {
            Log.mirror.info("H264 format changed: \(prev ? "AnnexB" : "AVCC") -> \(isAnnexB ? "AnnexB" : "AVCC")")
        }
        previousWasAnnexB = isAnnexB

        let nalUnits: [Data]
        if isAnnexB {
            nalUnits = parseNALUnits(from: data)
        } else {
            nalUnits = parseAVCCNALUnits(from: data)
        }

        var videoNALs: [Data] = []
        var formatChanged = false
        for nal in nalUnits {
            guard nal.count > 0 else { continue }
            let type = nal[0] & 0x1F
            switch type {
            case 7:
                if spsData != nal {
                    spsData = nal
                    formatChanged = true
                }
                if decodeCount <= 5 {
                    Log.mirror.info("SPS found, bytes=\(nal.count)")
                }
            case 8:
                if ppsData != nal {
                    ppsData = nal
                    formatChanged = true
                }
                if decodeCount <= 5 {
                    Log.mirror.info("PPS found, bytes=\(nal.count)")
                }
            case 1, 5:
                videoNALs.append(nal)
            default:
                break
            }
        }

        // Update format description if we have both SPS and PPS
        if let sps = spsData, let pps = ppsData {
            let didUpdate = updateFormatDescriptionIfNeeded(sps: sps, pps: pps)
            if didUpdate || formatChanged {
                DispatchQueue.main.async { [weak self] in
                    self?._displayLayer?.flush()
                }
            }
            let (w, h) = parseDimensions(from: sps)
            if w > 0 && h > 0 && (w != lastWidth || h != lastHeight) {
                lastWidth = w
                lastHeight = h
                DispatchQueue.main.async { [weak self] in
                    self?.onVideoDimensions?(w, h)
                }
            }
        }

        guard let formatDesc = formatDescription, !videoNALs.isEmpty else {
            if videoNALs.isEmpty && decodeCount <= 5 {
                Log.mirror.info("No video NALs in frame #\(self.decodeCount)")
            }
            return
        }

        // Build AVCC buffer from video NALs
        var avccData = Data()
        avccData.reserveCapacity(videoNALs.reduce(0) { $0 + 4 + $1.count })
        for nal in videoNALs {
            var length = UInt32(nal.count).bigEndian
            avccData.append(Data(bytes: &length, count: 4))
            avccData.append(nal)
        }

        let normalizedPts = normalizePts(pts)
        guard let sampleBuffer = createSampleBuffer(data: avccData, pts: normalizedPts, formatDescription: formatDesc) else {
            Log.mirror.error("Failed to create sample buffer")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self._displayLayer, layer.superlayer != nil else { return }
            if layer.status == .failed {
                if self.decodeCount <= 20 {
                    Log.mirror.error("AVSampleBufferDisplayLayer failed, flushing")
                }
                layer.flush()
                return
            }
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sampleBuffer)
            } else {
                if self.decodeCount <= 20 {
                    Log.mirror.warning("AVSampleBufferDisplayLayer not ready, dropping frame")
                }
            }
        }
    }

    // MARK: - Format Detection

    private func detectAnnexB(_ data: Data) -> Bool {
        if data.count >= 4 {
            if data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
                return true
            }
            if data[0] == 0 && data[1] == 0 && data[2] == 1 {
                return true
            }
        }
        let firstLength = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if firstLength > 0 && firstLength < UInt32(data.count) {
            return false
        }
        return true
    }

    // MARK: - NAL Parsing

    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var i = 0
        var scannedBytes = 0
        let maxScanWithoutStartCode = 1024

        while i < data.count {
            var startCodeLen = 0
            if i + 3 < data.count, data[i] == 0, data[i+1] == 0, data[i+2] == 0, data[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < data.count, data[i] == 0, data[i+1] == 0, data[i+2] == 1 {
                startCodeLen = 3
            }

            if startCodeLen > 0 {
                scannedBytes = 0
                let nalStart = i + startCodeLen
                var nalEnd = data.count
                for j in nalStart..<(data.count - 2) {
                    if data[j] == 0, data[j+1] == 0,
                       (data[j+2] == 1 || (j + 3 < data.count && data[j+2] == 0 && data[j+3] == 1)) {
                        nalEnd = j
                        break
                    }
                }
                if nalStart < nalEnd {
                    nalUnits.append(data.subdata(in: nalStart..<nalEnd))
                }
                i = nalEnd
            } else {
                i += 1
                scannedBytes += 1
                if scannedBytes > maxScanWithoutStartCode {
                    Log.mirror.warning("No start code found after scanning \(scannedBytes) bytes, falling back to AVCC")
                    return parseAVCCNALUnits(from: data)
                }
            }
        }

        return nalUnits
    }

    private func parseAVCCNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var offset = 0
        while offset + 4 < data.count {
            let length = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            let nalStart = offset + 4
            let nalEnd = nalStart + Int(length)
            guard length > 0, nalEnd <= data.count else { break }
            nalUnits.append(data.subdata(in: nalStart..<nalEnd))
            offset = nalEnd
        }
        return nalUnits
    }

    private func normalizePts(_ pts: Int64) -> Int64 {
        if let first = firstPts {
            return pts - first
        }
        firstPts = pts
        return 0
    }

    // MARK: - Format Description

    @discardableResult
    private func updateFormatDescriptionIfNeeded(sps: Data, pps: Data) -> Bool {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)

        var newDesc: CMVideoFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { spsPtr in
            ppsBytes.withUnsafeBufferPointer { ppsPtr in
                let ptrs = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes = [spsBytes.count, ppsBytes.count]
                return ptrs.withUnsafeBufferPointer { p in
                    sizes.withUnsafeBufferPointer { s in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: p.baseAddress!,
                            parameterSetSizes: s.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let desc = newDesc else {
            Log.mirror.error("Failed to create format description: \(status)")
            return false
        }

        if let existing = formatDescription {
            if !CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
                formatDescription = desc
                Log.mirror.info("H264 format description updated")
                return true
            }
        } else {
            formatDescription = desc
            Log.mirror.info("H264 format description created")
            return true
        }
        return false
    }

    // MARK: - SPS Dimension Parsing

    private func parseDimensions(from sps: Data) -> (width: Int, height: Int) {
        guard sps.count > 4 else { return (0, 0) }
        var bits = BitReader(data: sps)
        _ = bits.read(bits: 8)
        let profileIdc = bits.read(bits: 8)
        _ = bits.read(bits: 8)
        _ = bits.read(bits: 8)
        _ = bits.readExpGolomb()

        if profileIdc == 100 || profileIdc == 110 || profileIdc == 122 || profileIdc == 244 ||
           profileIdc == 44 || profileIdc == 83 || profileIdc == 86 || profileIdc == 118 ||
           profileIdc == 128 || profileIdc == 138 || profileIdc == 139 || profileIdc == 134 || profileIdc == 135 {
            let chromaFormatIdc = bits.readExpGolomb()
            if chromaFormatIdc == 3 {
                _ = bits.read(bits: 1)
            }
            _ = bits.readExpGolomb()
            _ = bits.readExpGolomb()
            _ = bits.read(bits: 1)
            let seqScalingMatrixPresent = bits.read(bits: 1)
            if seqScalingMatrixPresent == 1 {
                let limit = (chromaFormatIdc != 3) ? 8 : 12
                for i in 0..<limit {
                    let present = bits.read(bits: 1)
                    if present == 1 {
                        var lastScale = 8
                        var nextScale = 8
                        let size = (i < 6) ? 16 : 64
                        for _ in 0..<size {
                            if nextScale != 0 {
                                let deltaScale = bits.readSignedExpGolomb()
                                nextScale = (lastScale + deltaScale + 256) % 256
                            }
                            lastScale = (nextScale == 0) ? lastScale : nextScale
                        }
                    }
                }
            }
        }

        _ = bits.readExpGolomb()
        let picOrderCntType = bits.readExpGolomb()
        if picOrderCntType == 0 {
            _ = bits.readExpGolomb()
        } else if picOrderCntType == 1 {
            _ = bits.read(bits: 1)
            _ = bits.readSignedExpGolomb()
            _ = bits.readSignedExpGolomb()
            let numRefFramesInPicOrderCntCycle = bits.readExpGolomb()
            for _ in 0..<numRefFramesInPicOrderCntCycle {
                _ = bits.readSignedExpGolomb()
            }
        }
        _ = bits.readExpGolomb()
        _ = bits.read(bits: 1)
        let picWidthInMbsMinus1 = bits.readExpGolomb()
        let picHeightInMapUnitsMinus1 = bits.readExpGolomb()
        let frameMbsOnlyFlag = bits.read(bits: 1)

        if frameMbsOnlyFlag == 0 {
            _ = bits.read(bits: 1)
        }
        _ = bits.read(bits: 1)
        let frameCroppingFlag = bits.read(bits: 1)
        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if frameCroppingFlag == 1 {
            cropLeft = bits.readExpGolomb()
            cropRight = bits.readExpGolomb()
            cropTop = bits.readExpGolomb()
            cropBottom = bits.readExpGolomb()
        }

        let width = (picWidthInMbsMinus1 + 1) * 16 - cropLeft * 2 - cropRight * 2
        let height = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16 - cropTop * 2 - cropBottom * 2
        return (width, height)
    }

    private struct BitReader {
        private let data: Data
        private var byteOffset: Int = 0
        private var bitOffset: Int = 0

        init(data: Data) {
            self.data = data
        }

        mutating func read(bits: Int) -> Int {
            var result = 0
            for _ in 0..<bits {
                guard byteOffset < data.count else { break }
                let byte = data[byteOffset]
                let bit = (Int(byte) >> (7 - bitOffset)) & 1
                result = (result << 1) | bit
                bitOffset += 1
                if bitOffset == 8 {
                    bitOffset = 0
                    byteOffset += 1
                }
            }
            return result
        }

        mutating func readExpGolomb() -> Int {
            var leadingZeroBits = 0
            while read(bits: 1) == 0 {
                leadingZeroBits += 1
            }
            if leadingZeroBits == 0 {
                return 0
            }
            let codeValue = read(bits: leadingZeroBits)
            return (1 << leadingZeroBits) - 1 + codeValue
        }

        mutating func readSignedExpGolomb() -> Int {
            let codeNum = readExpGolomb()
            if codeNum % 2 == 1 {
                return (codeNum + 1) / 2
            } else {
                return -codeNum / 2
            }
        }
    }

    // MARK: - Sample Buffer Creation

    private func createSampleBuffer(data: Data, pts: Int64, formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        data.withUnsafeBytes { ptr in
            _ = CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: data.count)
        }

        let cmPts = CMTime(value: pts, timescale: 1000000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: cmPts,
            decodeTimeStamp: cmPts
        )

        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sb = sampleBuffer else { return nil }
        return sb
    }
}
