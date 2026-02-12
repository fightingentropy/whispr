import AVFoundation
import Foundation

final class LiveAudioCaptureService: AudioCaptureService {
    private let engine = AVAudioEngine()
    private let workQueue = DispatchQueue(label: "whispr.audio.capture")
    private let targetSampleRate: Double = 16_000
    private let maxRecordingDurationSeconds: Double = 120
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var capturedPCMData = Data()
    private var isCapturing = false
    private var inputLevelHandler: ((Float) -> Void)?
    private var smoothedInputLevel: Float = 0

    func start() throws {
        guard !isCapturing else { return }

        capturedPCMData.removeAll(keepingCapacity: true)
        smoothedInputLevel = 0
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw DictationError.audioCapture("Unable to create output audio format.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictationError.audioCapture("Unable to create audio converter.")
        }
        self.converter = converter
        self.targetFormat = targetFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let normalizedInputLevel = Self.normalizedInputLevel(from: buffer)
            self?.appendConvertedSamples(from: buffer)
            self?.publishInputLevel(normalizedInputLevel)
        }

        engine.prepare()
        do {
            try engine.start()
            isCapturing = true
            publishInputLevel(0)
        } catch {
            inputNode.removeTap(onBus: 0)
            converter.reset()
            self.converter = nil
            self.targetFormat = nil
            throw DictationError.audioCapture(error.localizedDescription)
        }
    }

    func stop() throws -> Data {
        guard isCapturing else {
            throw DictationError.audioCapture("Recording is not active.")
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        let pcmData = workQueue.sync { capturedPCMData }
        converter = nil
        targetFormat = nil
        publishInputLevel(0)

        guard !pcmData.isEmpty else {
            throw DictationError.audioCapture("No audio was captured.")
        }

        let wavData = buildWavData(fromPCM16: pcmData, sampleRate: Int(targetSampleRate))
        return wavData
    }

    func setInputLevelHandler(_ handler: ((Float) -> Void)?) {
        workQueue.async { [weak self] in
            self?.inputLevelHandler = handler
        }
    }

    private func appendConvertedSamples(from buffer: AVAudioPCMBuffer) {
        workQueue.async {
            guard let converter = self.converter, let targetFormat = self.targetFormat else { return }
            guard let convertedBuffer = self.convert(buffer: buffer, using: converter, to: targetFormat) else { return }
            guard convertedBuffer.frameLength > 0 else { return }
            guard let channelData = convertedBuffer.int16ChannelData else { return }

            let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
            let byteCount = Int(convertedBuffer.frameLength) * bytesPerFrame
            self.appendPCMBytes(from: channelData[0], byteCount: byteCount)
        }
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let expectedFrames = max(1, Int(ceil(Double(buffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(expectedFrames + 32)
        ) else {
            return nil
        }

        var didProvideInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func appendPCMBytes(from pointer: UnsafeMutablePointer<Int16>, byteCount: Int) {
        guard byteCount > 0 else { return }
        let remainingBytes = maxRecordingBytes - capturedPCMData.count
        guard remainingBytes > 0 else { return }

        let bytesToAppend = min(byteCount, remainingBytes)
        let rawPointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        capturedPCMData.append(rawPointer, count: bytesToAppend)
    }

    private func publishInputLevel(_ normalizedLevel: Float) {
        workQueue.async {
            let clampedLevel = max(0, min(1, normalizedLevel))
            let boostedLevel = pow(clampedLevel, 0.62)
            let riseSmoothing: Float = 0.5
            let fallSmoothing: Float = 0.17
            let smoothing = boostedLevel > self.smoothedInputLevel ? riseSmoothing : fallSmoothing
            self.smoothedInputLevel = (1 - smoothing) * self.smoothedInputLevel + smoothing * boostedLevel
            let level = self.smoothedInputLevel
            let handler = self.inputLevelHandler
            DispatchQueue.main.async {
                handler?(level)
            }
        }
    }

    private static func normalizedInputLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let channels = max(1, Int(buffer.format.channelCount))
        let sampleCount = max(1, frameLength * channels)
        let rms: Float

        if let floatChannelData = buffer.floatChannelData {
            var sumSquares: Float = 0
            for channel in 0..<channels {
                let samples = floatChannelData[channel]
                for index in 0..<frameLength {
                    let sample = samples[index]
                    sumSquares += sample * sample
                }
            }
            rms = sqrt(sumSquares / Float(sampleCount))
        } else if let int16ChannelData = buffer.int16ChannelData {
            var sumSquares: Float = 0
            let maxValue = Float(Int16.max)
            for channel in 0..<channels {
                let samples = int16ChannelData[channel]
                for index in 0..<frameLength {
                    let sample = Float(samples[index]) / maxValue
                    sumSquares += sample * sample
                }
            }
            rms = sqrt(sumSquares / Float(sampleCount))
        } else if let int32ChannelData = buffer.int32ChannelData {
            var sumSquares: Float = 0
            let maxValue = Float(Int32.max)
            for channel in 0..<channels {
                let samples = int32ChannelData[channel]
                for index in 0..<frameLength {
                    let sample = Float(samples[index]) / maxValue
                    sumSquares += sample * sample
                }
            }
            rms = sqrt(sumSquares / Float(sampleCount))
        } else {
            return 0
        }

        let minimumRMS: Float = 0.00001
        let decibels = 20 * log10(max(rms, minimumRMS))
        let normalized = (decibels + 58) / 52
        return max(0, min(1, normalized))
    }

    private var maxRecordingBytes: Int {
        Int(targetSampleRate * maxRecordingDurationSeconds) * MemoryLayout<Int16>.size
    }

    private func buildWavData(fromPCM16 pcmData: Data, sampleRate: Int) -> Data {
        let channelCount = 1
        let bytesPerSample = 2
        let byteRate = sampleRate * channelCount * bytesPerSample
        let blockAlign = UInt16(channelCount * bytesPerSample)
        let bitsPerSample: UInt16 = 16

        let dataChunkSize = UInt32(pcmData.count)
        let riffChunkSize = UInt32(36) + dataChunkSize

        var wav = Data(capacity: Int(riffChunkSize + 8))
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(littleEndianData(riffChunkSize))
        wav.append("WAVE".data(using: .ascii)!)

        wav.append("fmt ".data(using: .ascii)!)
        wav.append(littleEndianData(UInt32(16)))
        wav.append(littleEndianData(UInt16(1)))
        wav.append(littleEndianData(UInt16(channelCount)))
        wav.append(littleEndianData(UInt32(sampleRate)))
        wav.append(littleEndianData(UInt32(byteRate)))
        wav.append(littleEndianData(blockAlign))
        wav.append(littleEndianData(bitsPerSample))

        wav.append("data".data(using: .ascii)!)
        wav.append(littleEndianData(dataChunkSize))
        wav.append(pcmData)
        return wav
    }

    private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }
}
