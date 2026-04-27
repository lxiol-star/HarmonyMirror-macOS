import Foundation
import AVFoundation
import CoreMedia

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

    func bind(displayLayer: AVSampleBufferDisplayLayer) {
        self._displayLayer = displayLayer
        Log.mirror.info("H264VideoLayer bound to display layer")
    }

    nonisolated func feed(_ data: Data, pts: Int64, isKeyFrame: Bool) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.process(data, pts: pts)
        }
    }

    func flush() {
        displayLayer.flush()
    }

    func flushAndRemoveImage() {
        displayLayer.flushAndRemoveImage()
        // Reset all state for clean reconnection
        formatDescription = nil
        spsData = nil
        ppsData = nil
        previousWasAnnexB = nil
        decodeCount = 0
        lastWidth = 0
        lastHeight = 0
        firstPts = nil
    }

    // MARK: - Private

    nonisolated private func process(_ data: Data, pts: Int64) {
        decodeCount += 1
        if decodeCount <= 5 {
            Log.mirror.info("H264VideoLayer input #\(self.decodeCount), bytes=\(data.count)")
        }

        let maxFrameBytes = 2 * 1024 * 1024
        guard data.count > 4, data.count <= maxFrameBytes else {
            if decodeCount <= 5 {
                Log.mirror.warning("H264VideoLayer input #\(self.decodeCount) too short or too large (\(data.count)), skipping")
            }
            return
        }

        let isAnnexB = H264Parser.detectAnnexB(data)
        if let prev = previousWasAnnexB, prev != isAnnexB {
            Log.mirror.info("H264 format changed: \(prev ? "AnnexB" : "AVCC") -> \(isAnnexB ? "AnnexB" : "AVCC")")
        }
        previousWasAnnexB = isAnnexB

        let nalUnits = isAnnexB
            ? H264Parser.parseNALUnits(from: data)
            : H264Parser.parseAVCCNALUnits(from: data)

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

        if let sps = spsData, let pps = ppsData {
            let (newDesc, didUpdate) = H264Parser.updateFormatDescription(current: formatDescription, sps: sps, pps: pps)
            if let newDesc { formatDescription = newDesc }
            if didUpdate || formatChanged {
                DispatchQueue.main.async { [weak self] in
                    self?._displayLayer?.flush()
                }
            }
            let (w, h) = H264Parser.parseDimensions(from: sps)
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

        var avccData = Data()
        avccData.reserveCapacity(videoNALs.reduce(0) { $0 + 4 + $1.count })
        for nal in videoNALs {
            var length = UInt32(nal.count).bigEndian
            avccData.append(Data(bytes: &length, count: 4))
            avccData.append(nal)
        }

        let normalizedPts = normalizePts(pts)
        guard let sampleBuffer = H264Parser.createSampleBuffer(data: avccData, pts: normalizedPts, formatDescription: formatDesc) else {
            Log.mirror.error("Failed to create sample buffer")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self._displayLayer else { return }
            // Remove superlayer check - layer might not be in hierarchy yet during initial connection
            // The layer will buffer frames until it's added to the view hierarchy
            if layer.status == .failed {
                if self.decodeCount <= 20 {
                    Log.mirror.error("AVSampleBufferDisplayLayer failed, flushing")
                }
                layer.flush()
                return
            }
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sampleBuffer)
            } else if self.decodeCount <= 20 {
                Log.mirror.warning("AVSampleBufferDisplayLayer not ready, dropping frame")
            }
        }
    }

    private func normalizePts(_ pts: Int64) -> Int64 {
        if let first = firstPts {
            return pts - first
        }
        firstPts = pts
        return 0
    }
}
