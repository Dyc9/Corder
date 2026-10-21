import AVFoundation
import AudioToolbox

/// Microphone capture straight through a HAL output unit (AUHAL) bound to
/// ONE device from the start. Used when the default input is a Bluetooth
/// headset and the user hasn't picked a mic: AVAudioEngine's input node
/// always binds to the default input first, and on a headset that alone
/// flips it to HFP (measured 3.1 s, and call-quality sound in the user's
/// ears), and re-pointing it afterwards fails with -10868. AUHAL takes the
/// device before it ever opens, so the headset stays in A2DP; first buffer
/// in ~0.25 s (measured 2026-10-21, Bluetooth default, built-in mic).
/// Same approach as Hyprnote/Char (cpal, i.e. AUHAL + CurrentDevice).
final class HALMicCapture: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    let format: AVAudioFormat
    private var unit: AudioUnit?
    private let scratch: AVAudioPCMBuffer
    private let handler: Handler

    enum Failure: Error { case noComponent, status(String, OSStatus), badFormat }

    /// Builds and starts the unit on `deviceID`. `handler` runs on the
    /// HAL's real-time thread with a buffer that is reused, copy it.
    init(deviceID: AudioDeviceID, handler: @escaping Handler) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw Failure.noComponent }
        var u: AudioUnit?
        try Self.check("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &u))
        guard let au = u else { throw Failure.noComponent }
        var ok = false
        defer { if !ok { AudioComponentInstanceDispose(au) } }

        var one: UInt32 = 1, zero: UInt32 = 0
        try Self.check("EnableIO input", AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4))
        try Self.check("EnableIO output", AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4))
        var dev = deviceID
        try Self.check("CurrentDevice", AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check("hardware format", AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size))
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate,
                                      channels: hw.mChannelsPerFrame, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_384) else { throw Failure.badFormat }
        var client = fmt.streamDescription.pointee
        try Self.check("client format", AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))
        var maxFrames: UInt32 = 16_384
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)

        self.format = fmt
        self.scratch = buf
        self.handler = handler
        self.unit = au

        var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
            let me = Unmanaged<HALMicCapture>.fromOpaque(refCon).takeUnretainedValue()
            return me.render(flags: flags, ts: ts, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check("input callback", AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                              &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try Self.check("AudioUnitInitialize", AudioUnitInitialize(au))
        do {
            try Self.check("AudioOutputUnitStart", AudioOutputUnitStart(au))
        } catch {
            AudioUnitUninitialize(au)
            throw error
        }
        ok = true
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, ts: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard let au = unit, frames <= scratch.frameCapacity else { return noErr }
        scratch.frameLength = frames
        let abl = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        for i in 0..<abl.count { abl[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
        let status = AudioUnitRender(au, flags, ts, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr else { return status }
        let t = ts.pointee
        let when = t.mFlags.contains(.hostTimeValid) ? AVAudioTime(hostTime: t.mHostTime) : AVAudioTime(sampleTime: Int64(t.mSampleTime), atRate: format.sampleRate)
        handler(scratch, when)
        return noErr
    }

    func stop() {
        guard let au = unit else { return }
        unit = nil
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
    }

    deinit { stop() }

    private static func check(_ what: String, _ status: OSStatus) throws {
        if status != noErr { throw Failure.status(what, status) }
    }
}
