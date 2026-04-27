import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

/// H264Decoder parses incoming H264 data (AnnexB or AVCC) and produces CMSampleBuffers
/// suitable for direct display via AVSampleBufferDisplayLayer.
final class H264Decoder {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onVideoDimensions: ((Int, Int) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var previousWasAnnexB: Bool?
    private let decodeQueue = DispatchQueue(label: "com.harmonymirror.decode", qos: .userInitiated)
    private var decodeCount = 0
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    func decode(_ data: Data, pts: Int64, isKeyFrame: Bool) {
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.decodeInternal(data, pts: pts)
        }
    }

    private func decodeInternal(_ data: Data, pts: Int64) {
        decodeCount += 1
        if decodeCount <= 5 {
            Log.mirror.info("decoder input #\(self.decodeCount), bytes=\(data.count)")
        }

        guard data.count > 4 else {
            if decodeCount <= 5 {
                Log.mirror.warning("decoder input #\(self.decodeCount) too short, skipping")
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
        for nal in nalUnits {
            guard nal.count > 0 else { continue }
            let type = nal[0] & 0x1F
            switch type {
            case 7:
                spsData = nal
                if decodeCount <= 5 {
                    Log.mirror.info("SPS found, bytes=\(nal.count)")
                }
            case 8:
                ppsData = nal
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
            updateFormatDescriptionIfNeeded(sps: sps, pps: pps)
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

        guard let sampleBuffer = createSampleBuffer(data: avccData, pts: pts, formatDescription: formatDesc) else {
            Log.mirror.error("Failed to create sample buffer")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onSampleBuffer?(sampleBuffer)
        }
    }

    // MARK: - Format Detection

    private func detectAnnexB(_ data: Data) -> Bool {
        // Check for start code at the beginning
        if data.count >= 4 {
            if data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
                return true
            }
            if data[0] == 0 && data[1] == 0 && data[2] == 1 {
                return true
            }
        }
        // If first 4 bytes look like a reasonable AVCC length (non-zero, not too large), treat as AVCC
        let firstLength = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if firstLength > 0 && firstLength < UInt32(data.count) {
            return false
        }
        // Default to AnnexB if ambiguous
        return true
    }

    // MARK: - NAL Parsing

    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var i = 0

        while i < data.count {
            var startCodeLen = 0
            if i + 3 < data.count, data[i] == 0, data[i+1] == 0, data[i+2] == 0, data[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < data.count, data[i] == 0, data[i+1] == 0, data[i+2] == 1 {
                startCodeLen = 3
            }

            if startCodeLen > 0 {
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

    // MARK: - Format Description

    private func updateFormatDescriptionIfNeeded(sps: Data, pps: Data) {
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
            return
        }

        if let existing = formatDescription {
            if !CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
                formatDescription = desc
                Log.mirror.info("H264 format description updated")
            }
        } else {
            formatDescription = desc
            Log.mirror.info("H264 format description created")
        }
    }

    // MARK: - SPS Dimension Parsing

    private func parseDimensions(from sps: Data) -> (width: Int, height: Int) {
        // Simple H.264 SPS parser for baseline/main/high profile
        guard sps.count > 4 else { return (0, 0) }
        var bits = BitReader(data: sps)
        // Skip forbidden_zero_bit, nal_ref_idc, nal_unit_type (8 bits)
        _ = bits.read(bits: 8)
        // profile_idc (8 bits)
        let profileIdc = bits.read(bits: 8)
        // constraint_set flags + reserved (8 bits)
        _ = bits.read(bits: 8)
        // level_idc (8 bits)
        _ = bits.read(bits: 8)
        // seq_parameter_set_id (exp-golomb)
        _ = bits.readExpGolomb()

        if profileIdc == 100 || profileIdc == 110 || profileIdc == 122 || profileIdc == 244 ||
           profileIdc == 44 || profileIdc == 83 || profileIdc == 86 || profileIdc == 118 ||
           profileIdc == 128 || profileIdc == 138 || profileIdc == 139 || profileIdc == 134 || profileIdc == 135 {
            // chroma_format_idc
            let chromaFormatIdc = bits.readExpGolomb()
            if chromaFormatIdc == 3 {
                // separate_colour_plane_flag
                _ = bits.read(bits: 1)
            }
            // bit_depth_luma_minus8
            _ = bits.readExpGolomb()
            // bit_depth_chroma_minus8
            _ = bits.readExpGolomb()
            // qpprime_y_zero_transform_bypass_flag
            _ = bits.read(bits: 1)
            // seq_scaling_matrix_present_flag
            let seqScalingMatrixPresent = bits.read(bits: 1)
            if seqScalingMatrixPresent == 1 {
                let limit = (chromaFormatIdc != 3) ? 8 : 12
                for i in 0..<limit {
                    let present = bits.read(bits: 1)
                    if present == 1 {
                        // skip scaling list, up to 64 entries
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

        // log2_max_frame_num_minus4
        _ = bits.readExpGolomb()
        // pic_order_cnt_type
        let picOrderCntType = bits.readExpGolomb()
        if picOrderCntType == 0 {
            // log2_max_pic_order_cnt_lsb_minus4
            _ = bits.readExpGolomb()
        } else if picOrderCntType == 1 {
            // delta_pic_order_always_zero_flag
            _ = bits.read(bits: 1)
            // offset_for_non_ref_pic
            _ = bits.readSignedExpGolomb()
            // offset_for_top_to_bottom_field
            _ = bits.readSignedExpGolomb()
            let numRefFramesInPicOrderCntCycle = bits.readExpGolomb()
            for _ in 0..<numRefFramesInPicOrderCntCycle {
                _ = bits.readSignedExpGolomb()
            }
        }
        // max_num_ref_frames
        _ = bits.readExpGolomb()
        // gaps_in_frame_num_value_allowed_flag
        _ = bits.read(bits: 1)
        // pic_width_in_mbs_minus1
        let picWidthInMbsMinus1 = bits.readExpGolomb()
        // pic_height_in_map_units_minus1
        let picHeightInMapUnitsMinus1 = bits.readExpGolomb()
        // frame_mbs_only_flag
        let frameMbsOnlyFlag = bits.read(bits: 1)

        if frameMbsOnlyFlag == 0 {
            // mb_adaptive_frame_field_flag
            _ = bits.read(bits: 1)
        }
        // direct_8x8_inference_flag
        _ = bits.read(bits: 1)
        // frame_cropping_flag
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

    // MARK: - BitReader helper

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

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: pts, timescale: 1000000),
            decodeTimeStamp: CMTime.invalid
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
