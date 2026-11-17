import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 / H.265 decoding of NAL units into BGRA frames.
final class VideoDecoder {
    enum Codec: Sendable { case h264, h265 }

    var onFrame: ((CVPixelBuffer) -> Void)?

    private let codec: Codec
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sawKeyframe = false

    init(codec: Codec) { self.codec = codec }

    deinit { reset() }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sawKeyframe = false
    }

    private enum Kind { case vps, sps, pps, keyframe, slice, other }

    private func kind(_ nal: Data) -> Kind {
        guard let first = nal.first else { return .other }
        switch codec {
        case .h264:
            switch first & 0x1F {
            case 7: return .sps
            case 8: return .pps
            case 5: return .keyframe
            case 1...4: return .slice
            default: return .other
            }
        case .h265:
            switch (first >> 1) & 0x3F {
            case 32: return .vps
            case 33: return .sps
            case 34: return .pps
            case 16...21: return .keyframe
            case 0...9: return .slice
            default: return .other
            }
        }
    }

    /// Parameter sets from the stream description (the camera may also repeat them in the video).
    func setParameterSets(_ sets: [Data]) {
        for set in sets { store(set) }
    }

    private func store(_ nal: Data) {
        switch kind(nal) {
        case .vps: if vps != nal { vps = nal; format = nil }
        case .sps: if sps != nal { sps = nal; format = nil }
        case .pps: if pps != nal { pps = nal; format = nil }
        default: break
        }
    }

    /// Decodes one picture, given as its NAL units without start codes.
    func decode(_ nals: [Data]) {
        var picture: [Data] = []
        var isKeyframe = false
        for nal in nals {
            switch kind(nal) {
            case .vps, .sps, .pps: store(nal)
            case .keyframe: isKeyframe = true; picture.append(nal)
            case .slice: picture.append(nal)
            case .other: break
            }
        }
        guard !picture.isEmpty else { return }
        if format == nil {
            guard makeFormat() else { return }
            sawKeyframe = false
        }
        if isKeyframe { sawKeyframe = true }
        guard sawKeyframe, let session, let format else { return }   // wait for a picture that stands alone

        // Length-prefixed NAL units, as VideoToolbox expects.
        var data = Data(capacity: picture.reduce(0) { $0 + $1.count + 4 })
        for nal in picture {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        var sample: CMSampleBuffer?
        var size = data.count
        guard copied == noErr, CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            if status == noErr, let image { self?.onFrame?(image) }
        }
        if status != noErr { reset() }      // start again from the next keyframe
    }

    private func makeFormat() -> Bool {
        var sets: [Data] = []
        switch codec {
        case .h264:
            guard let sps, let pps else { return false }
            sets = [sps, pps]
        case .h265:
            guard let vps, let sps, let pps else { return false }
            sets = [vps, sps, pps]
        }
        // Keep the bytes alive and pinned while Core Media copies them.
        let pinned = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: copy, count: set.count)
            return copy
        }
        defer { pinned.forEach { $0.deallocate() } }
        let pointers = pinned.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var made: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &made)
        }
        guard status == noErr, let made else { return false }

        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let output: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: made, decoderSpecification: nil,
            imageBufferAttributes: output as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created) == noErr, let created else { return false }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = made
        return true
    }
}
