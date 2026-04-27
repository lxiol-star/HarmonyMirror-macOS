import Foundation
import CoreMedia

enum H264Parser {
    // MARK: - Format Detection

    static func detectAnnexB(_ data: Data) -> Bool {
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

    static func parseNALUnits(from data: Data) -> [Data] {
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
                    return parseAVCCNALUnits(from: data)
                }
            }
        }

        return nalUnits
    }

    static func parseAVCCNALUnits(from data: Data) -> [Data] {
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

    // MARK: - Format Description

    @discardableResult
    static func updateFormatDescription(current: CMVideoFormatDescription?, sps: Data, pps: Data) -> (CMVideoFormatDescription?, Bool) {
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
            return (current, false)
        }

        if let existing = current {
            if !CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
                Log.mirror.info("H264 format description updated")
                return (desc, true)
            }
            return (current, false)
        }

        Log.mirror.info("H264 format description created")
        return (desc, true)
    }

    // MARK: - SPS Dimension Parsing

    static func parseDimensions(from sps: Data) -> (width: Int, height: Int) {
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

    // MARK: - Sample Buffer Creation

    static func createSampleBuffer(data: Data, pts: Int64, timescale: Int32 = 60, formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
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

        let cmPts = CMTime(value: pts, timescale: timescale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: cmPts,
            decodeTimeStamp: .invalid
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

    // MARK: - BitReader

    struct BitReader {
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
                guard leadingZeroBits <= 32 else { return 0 }
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
}
