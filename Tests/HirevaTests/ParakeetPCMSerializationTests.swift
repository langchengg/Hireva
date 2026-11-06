import AVFoundation
import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet PCM serialization")
struct ParakeetPCMSerializationTests {
    @Test(arguments: [false, true])
    func float32StereoPreservesFrameStrideAndDownmix(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        #expect(buffer.stride == (interleaved ? 2 : 1))
        if interleaved {
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            #expect(buffers.count == 1)
            let samples = try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)
            copy([1, 0, 3, 2, -2, 6], to: samples)
        } else {
            let channels = try #require(buffer.floatChannelData)
            copy([1, 3, -2], to: channels[0])
            copy([0, 2, 6], to: channels[1])
        }

        let event = try #require(ParakeetSidecarRuntimeClient.audioEventData(from: buffer, sequence: 19, source: .systemAudio))
        let decoded = try decode(event)
        #expect(decoded.samples == [0.5, 2.5, 2])
        #expect(decoded.payload["channels"] as? Int == 1)
        #expect(decoded.payload["sampleRate"] as? Double == 48_000)
    }

    @Test
    func float32MonoPreservesSamplesAndEventMetadata() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        copy([-1, 0, 0.25, 1], to: channels[0])

        let event = try #require(ParakeetSidecarRuntimeClient.audioEventData(from: buffer, sequence: 31, source: .microphone))
        let decoded = try decode(event)
        #expect(decoded.samples == [-1, 0, 0.25, 1])
        #expect(decoded.payload["type"] as? String == "audio")
        #expect(decoded.payload["sequence"] as? Int == 31)
        #expect(decoded.payload["sampleRate"] as? Double == 16_000)
        #expect(decoded.payload["channels"] as? Int == 1)
        #expect(decoded.payload["encoding"] as? String == "float32le")
        #expect(decoded.payload["audioSource"] as? String == AudioSourceType.microphone.rawValue)
    }

    @Test
    func emptyBufferDoesNotSerializeAnAudioEvent() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        #expect(buffer.frameLength == 0)
        #expect(ParakeetSidecarRuntimeClient.audioEventData(from: buffer, sequence: 1, source: .systemAudio) == nil)
    }

    @Test
    func unsupportedFloat64DoesNotSerializeAsFloat32() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        #expect(buffer.floatChannelData == nil)
        #expect(ParakeetSidecarRuntimeClient.audioEventData(from: buffer, sequence: 1, source: .systemAudio) == nil)
    }

    private func copy(_ samples: [Float], to destination: UnsafeMutablePointer<Float>) {
        samples.withUnsafeBufferPointer { source in
            if let start = source.baseAddress { destination.update(from: start, count: source.count) }
        }
    }

    private func decode(_ event: Data) throws -> (payload: [String: Any], samples: [Float]) {
        let payload = try #require(JSONSerialization.jsonObject(with: event) as? [String: Any])
        let encoded = try #require(payload["audio"] as? String)
        let audio = try #require(Data(base64Encoded: encoded))
        #expect(audio.count.isMultiple(of: MemoryLayout<Float>.size))
        let samples = audio.withUnsafeBytes { bytes in
            (0..<(bytes.count / MemoryLayout<Float>.size)).map { index in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: UInt32.self)))
            }
        }
        return (payload, samples)
    }
}
