// SPDX-License-Identifier: MIT
// AquaVR phase 3: ported from alvr-visionos ALVRClient/VideoHandler.swift (AGPL-3.0).
// iOS adaptation:
//   - H264/HEVC only (A14 has no AV1 hardware decode; capabilities advertise encoder_av1=false).
//   - Decoder output pixel format is pinned to 8-bit 4:2:0 biplanar video range
//     (deterministic planes for the single-eye Metal renderer).
//   - Limited-range YCbCr matrices included (donor kept them commented).

import Foundation
import VideoToolbox
import AVFoundation
import CoreVideo
import Metal

struct VideoHandler {
    static func createVideoDecoder(initialNals: UnsafeMutableBufferPointer<UInt8>, codec: Int) -> (VTDecompressionSession?, CMFormatDescription?) {
        var videoFormat: CMFormatDescription? = nil
        var err: OSStatus = 0

        if codec == ALVR_CODEC_H264.rawValue {
            (err, videoFormat) = createH264VideoDecoderDesc(initialNals: initialNals)
        } else if codec == ALVR_CODEC_HEVC.rawValue {
            (err, videoFormat) = createHEVCVideoDecoderDesc(initialNals: initialNals)
        } else {
            print("Unknown codec type \(codec)")
            return (nil, nil)
        }

        if err != 0 {
            print("format fail?! \(err)")
            return (nil, nil)
        }

        if videoFormat == nil {
            return (nil, nil)
        }

        print(videoFormat!)

        let videoDecoderSpecification: [NSString: AnyObject] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue
        ]
        // Pin the output plane layout: NVENC streams are 8-bit 4:2:0; keep the decoder from
        // negotiating exotic/downconverted formats.
        let destinationImageBufferAttributes: [NSString: AnyObject] = [
            kCVPixelBufferMetalCompatibilityKey: true as NSNumber,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as NSNumber,
            kCVPixelBufferPoolMinimumBufferCountKey: 3 as NSNumber
        ]

        var decompressionSession: VTDecompressionSession? = nil
        err = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: videoFormat!,
            decoderSpecification: videoDecoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession)
        if err != 0 {
            print("VTDecompressionSessionCreate err?! \(err)")
            return (nil, nil)
        }

        if decompressionSession == nil {
            print("no session??")
            return (nil, nil)
        }

        return (decompressionSession!, videoFormat!)
    }

    // MARK: - CMFormatDescription gymnastics

    static func createH264VideoDecoderDesc(initialNals: UnsafeMutableBufferPointer<UInt8>) -> (OSStatus, CMFormatDescription?) {
        var videoFormat: CMFormatDescription? = nil
        var err: OSStatus = 0

        err = initialNals.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            // First two NALs are the SPS and PPS
            let nalHeader: [UInt8] = [0x00, 0x00, 0x00, 0x01]

            let nalOffset0 = b.baseAddress!
            let nalOffset1 = memmem(nalOffset0 + 4, b.count - 4, nalHeader, nalHeader.count)!
            let nalLength0 = UnsafeRawPointer(nalOffset1) - nalOffset0 - 4
            let nalLength1 = b.baseAddress! + b.count - UnsafeRawPointer(nalOffset1) - 4

            let parameterSetPointers = [
                (nalOffset0 + 4).assumingMemoryBound(to: UInt8.self),
                UnsafeRawPointer(nalOffset1 + 4).assumingMemoryBound(to: UInt8.self)
            ]
            let parameterSetSizes = [nalLength0, nalLength1]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil,
                parameterSetCount: 2,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &videoFormat)
        }

        return (err, videoFormat)
    }

    static func createHEVCVideoDecoderDesc(initialNals: UnsafeMutableBufferPointer<UInt8>) -> (OSStatus, CMFormatDescription?) {
        var videoFormat: CMFormatDescription? = nil
        var err: OSStatus = 0

        let (vps, sps, pps, sei) = extractParameterSets(from: initialNals)

        var parameterSetPointers: [UnsafePointer<UInt8>?] = []
        var parameterSetSizes: [Int] = []

        for parameterSet in [vps, sps, pps, sei] {
            if let parameterSet = parameterSet {
                parameterSet.withUnsafeBytes { rawBufferPointer in
                    if let baseAddress = rawBufferPointer.baseAddress {
                        parameterSetPointers.append(baseAddress.assumingMemoryBound(to: UInt8.self))
                        parameterSetSizes.append(parameterSet.count)
                    }
                }
            }
        }

        let nonOptionalParameterSetPointers = parameterSetPointers.compactMap { $0 }

        nonOptionalParameterSetPointers.withUnsafeBufferPointer { pointersBuffer in
            guard let pointersBase = pointersBuffer.baseAddress else { return }
            parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                guard let sizesBase = sizesBuffer.baseAddress else { return }

                let nalUnitHeaderLength: Int32 = 4

                let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: pointersBase,
                    parameterSetSizes: sizesBase,
                    nalUnitHeaderLength: nalUnitHeaderLength,
                    extensions: nil,
                    formatDescriptionOut: &videoFormat)

                if status == noErr, videoFormat != nil {
                    print("Successfully created HEVC CMVideoFormatDescription.")
                } else {
                    print("Failed to create HEVC CMVideoFormatDescription.")
                }
            }
        }

        return (err, videoFormat)
    }

    // MARK: - CMSampleBuffer gymnastics

    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    private static func annexBBufferToCMSampleBuffer(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription) -> CMSampleBuffer? {
        let (naluIndices, elgibleForModifyInPlace) = findNaluIndices(bufferBounded: buffer)

        if elgibleForModifyInPlace {
            return annexBBufferToCMSampleBufferModifyInPlace(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
        else {
            return annexBBufferToCMSampleBufferWithCopy(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
    }

    private static func annexBBufferToCMSampleBufferWithCopy(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription, naluIndices: [NaluIndex]) -> CMSampleBuffer? {
        var err: OSStatus = 0

        // Replace 3/4-byte NAL headers with 4-byte lengths; add a byte for each 3-byte header.
        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        let blockBuffer = try! CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow)

        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                print("CMBlockBufferCreateContiguous error")
                return nil
            }
        } else {
            contiguousBuffer = blockBuffer
        }

        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            print("CMBlockBufferGetDataPointer error")
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))!
        var offset = 0

        buffer.withUnsafeBytes { (unsafeBytes) in
            let bytes = unsafeBytes.bindMemory(to: UInt8.self).baseAddress!

            for index in naluIndices {
                pointer.advanced(by: offset    ).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >>  8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize      ) & 0xFF)
                offset += 4

                pointer.advanced(by: offset).update(from: bytes.advanced(by: index.payloadStartOffset), count: blockBufferSize - offset)
                offset += index.payloadSize
            }
        }

        var sampleBuffer: CMSampleBuffer!
        err = CMSampleBufferCreate(allocator: nil, dataBuffer: contiguousBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        if err != 0 {
            print("CMSampleBufferCreate error")
            return nil
        }

        return sampleBuffer
    }

    private static func annexBBufferToCMSampleBufferModifyInPlace(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription, naluIndices: [NaluIndex]) -> CMSampleBuffer? {
        var err: OSStatus = 0
        var offset = 0

        let umrbp = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
        let bb = try! CMBlockBuffer.init(buffer: umrbp, deallocator: {(_, _) in }, flags: .assureMemoryNow)

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(buffer.baseAddress!))!
        for index in naluIndices {
            pointer.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >>  8) & 0xFF)
            pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize      ) & 0xFF)
            offset += 4

            offset += index.payloadSize
        }

        var sampleBuffer: CMSampleBuffer!
        err = CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        if err != 0 {
            print("CMSampleBufferCreate error")
            return nil
        }

        return sampleBuffer
    }

    // MARK: - Feed the decoder

    static func feedVideoIntoDecoder(
        decompressionSession: VTDecompressionSession,
        nals: UnsafeMutableBufferPointer<UInt8>,
        timestamp: UInt64,
        videoFormat: CMFormatDescription,
        codec: Int,
        callback: @escaping (_ imageBuffer: CVImageBuffer?) -> Void
    ) {
        guard let sampleBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: videoFormat) else {
            print("Failed in annexBBufferToCMSampleBuffer")
            return
        }
        let decoded = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 0),
            infoFlagsOut: nil) { (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, taggedBuffers: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
            if status < 0 && AlvrSession.shared.framesSinceLastIDR > Int(AlvrSession.shared.refreshRate) * 2 {
                AlvrSession.shared.framesSinceLastIDR = 0
                AlvrSession.shared.needsEncoderReset = true
            }

            callback(imageBuffer)
        }
        if decoded != 0 {
            print("VTDecompressionSessionDecodeFrame err \(decoded)")
        }
    }

    // MARK: - YUV -> RGB matrices
    // Reference: https://kdashg.github.io/misc/colors/from-coeffs.html

    static func getYUVTransformForVideoFormat(_ videoFormat: CMFormatDescription) -> simd_float4x4 {
        let fmtYCbCrMatrixRaw = videoFormat.extensions["CVImageBufferYCbCrMatrix" as CFString]
        let fmtYCbCrMatrix = (fmtYCbCrMatrixRaw != nil ? fmtYCbCrMatrixRaw as! CFString : "unknown" as CFString)

        let bt601ToRGBFull8bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000),
            simd_float4(+0.0000000, -0.3454912, +1.7789764, +0.0000),
            simd_float4(+1.4075197, -0.7169478, +0.0000000, +0.0000),
            simd_float4(-0.7065197, +0.5333027, -0.8929764, +1.0000)]
        );

        let bt709ToRGBFull8bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000),
            simd_float4(+0.0000000, -0.1880618, +1.8629055, +0.0000),
            simd_float4(+1.5810000, -0.4699673, +0.0000000, +0.0000),
            simd_float4(-0.7936000, +0.3303048, -0.9351055, +1.0000)]
        );

        let bt601ToRGBLimited = simd_float4x4([
            simd_float4(+1.1644, +1.1644, +1.1644, +0.0000),
            simd_float4(+0.0000, -0.3918, +2.0172, +0.0000),
            simd_float4(+1.5960, -0.8130, +0.0000, +0.0000),
            simd_float4(-0.8708, +0.5296, -1.0814, +1.0000)]
        );

        let bt709ToRGBLimited = simd_float4x4([
            simd_float4(+1.1644, +1.1644, +1.1644, +0.0000),
            simd_float4(+0.0000, -0.2133, +2.1125, +0.0000),
            simd_float4(+1.7969, -0.5342, +0.0000, +0.0000),
            simd_float4(-0.9750, +0.3021, -1.1333, +1.0000)]
        );

        let isFullRange = ((videoFormat.extensions["FullRangeVideo" as CFString] != nil
            ? videoFormat.extensions["FullRangeVideo" as CFString] as! NSNumber : 0).intValue != 0)

        if isFullRange {
            switch fmtYCbCrMatrix {
            case kCVImageBufferYCbCrMatrix_ITU_R_601_4:
                return bt601ToRGBFull8bit
            case kCVImageBufferYCbCrMatrix_ITU_R_709_2:
                return bt709ToRGBFull8bit
            default:
                return bt709ToRGBFull8bit
            }
        }
        else {
            switch fmtYCbCrMatrix {
            case kCVImageBufferYCbCrMatrix_ITU_R_601_4:
                return bt601ToRGBLimited
            case kCVImageBufferYCbCrMatrix_ITU_R_709_2:
                return bt709ToRGBLimited
            default:
                return bt709ToRGBLimited
            }
        }
    }
}
