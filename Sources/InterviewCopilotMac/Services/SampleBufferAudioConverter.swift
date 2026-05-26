import AVFoundation
import CoreMedia
import Foundation

public enum AudioConversionError: LocalizedError {
    case invalidFormatDescription
    case zeroSamples
    case allocationFailed
    case copyFailed(OSStatus)
    case converterCreationFailed
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormatDescription:
            return "The sample buffer format description is missing or invalid."
        case .zeroSamples:
            return "The sample buffer contains zero samples."
        case .allocationFailed:
            return "Failed to allocate the target AVAudioPCMBuffer."
        case .copyFailed(let status):
            return "Failed to copy PCM data into the audio buffer list. OSStatus: \(status)"
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for sample rate/channel conversion."
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        }
    }
}

public final class SampleBufferAudioConverter {
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var cachedOutputFormat: AVAudioFormat?

    public init() {}

    /// Safely converts a CMSampleBuffer to an AVAudioPCMBuffer, optionally converting it to a target output format.
    public func convert(
        sampleBuffer: CMSampleBuffer,
        targetFormat: AVAudioFormat? = nil
    ) throws -> AVAudioPCMBuffer {
        // 1. Validate format description and basic stream properties
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw AudioConversionError.invalidFormatDescription
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else {
            throw AudioConversionError.zeroSamples
        }

        // 2. Wrap/Represent the source format description into an AVAudioFormat
        var sourceStreamDescription = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &sourceStreamDescription) else {
            throw AudioConversionError.allocationFailed
        }

        // 3. Allocate AVAudioPCMBuffer matching input format and copy CMSampleBuffer raw data
        let frameCapacity = AVAudioFrameCount(numSamples)
        guard let inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw AudioConversionError.allocationFailed
        }
        inputPCMBuffer.frameLength = frameCapacity

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inputPCMBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioConversionError.copyFailed(status)
        }

        // 4. If no target format or input format matches target format, return extracted buffer directly
        guard let outputFormat = targetFormat, inputFormat != outputFormat else {
            return inputPCMBuffer
        }

        // 5. Build/Cache AVAudioConverter for target format conversion
        let converter = try getOrCreateConverter(from: inputFormat, to: outputFormat)

        // Determine output frame count based on sample rate ratio
        let sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(frameCapacity) * sampleRateRatio)
        
        guard let outputPCMBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            throw AudioConversionError.allocationFailed
        }

        // 6. Perform AVSampleBuffer conversion block
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputPCMBuffer
        }

        let result = converter.convert(
            to: outputPCMBuffer,
            error: &error,
            withInputFrom: inputBlock
        )

        if result == .error || error != nil {
            throw AudioConversionError.conversionFailed(
                error?.localizedDescription ?? "Unknown conversion failure"
            )
        }

        return outputPCMBuffer
    }

    private func getOrCreateConverter(
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioConverter {
        if let converter = cachedConverter,
           cachedInputFormat == inputFormat,
           cachedOutputFormat == outputFormat {
            return converter
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioConversionError.converterCreationFailed
        }

        // Configure premium converter settings
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        
        self.cachedConverter = converter
        self.cachedInputFormat = inputFormat
        self.cachedOutputFormat = outputFormat
        return converter
    }
}
