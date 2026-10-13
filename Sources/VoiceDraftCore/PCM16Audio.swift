import Foundation
import CoreMedia
import AudioToolbox

/// Validate the negotiated capture format before any bytes reach a provider.
public enum PCM16Audio {
    public static func data(from buffer: CMSampleBuffer) throws -> Data {
        guard CMSampleBufferDataIsReady(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mSampleRate == 16_000,
              description.mChannelsPerFrame == 1, description.mBitsPerChannel == 16,
              description.mBytesPerFrame == 2,
              description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              description.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
              let block = CMSampleBufferGetDataBuffer(buffer) else { throw invalidFormat() }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 0, count <= 64_000, count == CMSampleBufferGetNumSamples(buffer) * 2 else { throw invalidFormat() }
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw invalidFormat() }
        return bytes
    }
    public static func level(_ bytes: Data) -> Double {
        guard bytes.count >= 2 else { return 0 }
        let energy = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stride(from: 0, to: raw.count - 1, by: 2).reduce(0.0) { sum, offset in
                let sample = Double(Int16(bitPattern: UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8)) / 32768
                return sum + sample * sample
            }
        }
        return min(1, sqrt(energy / Double(bytes.count / 2)) * 5)
    }
    private static func invalidFormat() -> VoiceDraftError {
        .message("The recording format is unsupported. Choose another audio input device.")
    }
}
