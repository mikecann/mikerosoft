import AVFoundation
import CoreMedia

func withAudioPCMBuffer<Result>(
    from sampleBuffer: CMSampleBuffer,
    _ body: (AVAudioPCMBuffer) throws -> Result
) throws -> Result {
    guard CMSampleBufferDataIsReady(sampleBuffer) else {
        throw RecordItError.message("The selected input supplied an audio sample that was not ready.")
    }
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw RecordItError.message("The selected input did not provide an audio format.")
    }
    let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard format.sampleRate > 0, format.channelCount > 0, frameCount > 0 else {
        throw RecordItError.message("The selected input did not provide usable PCM audio.")
    }

    var audioBufferListSize = 0
    var retainedBlockBuffer: CMBlockBuffer?
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &audioBufferListSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &retainedBlockBuffer
    )
    guard sizeStatus == noErr, audioBufferListSize >= MemoryLayout<AudioBufferList>.size else {
        throw RecordItError.message(
            "The selected input's PCM layout could not be read. Core Media returned OSStatus \(sizeStatus)."
        )
    }

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: audioBufferListSize,
        alignment: 16
    )
    defer { storage.deallocate() }
    let audioBufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
    let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: audioBufferListSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &retainedBlockBuffer
    )
    guard listStatus == noErr else {
        throw RecordItError.message(
            "The selected input's PCM buffers could not be read. Core Media returned OSStatus \(listStatus)."
        )
    }

    // AVAudioPCMBuffer understands the AudioBufferList's native sample type and
    // planar/interleaved layout. Keeping the CMBlockBuffer alive through `body`
    // lets AVAudioFile consume it without any manual byte copying.
    guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        bufferListNoCopy: audioBufferList,
        deallocator: nil
    ) else {
        throw RecordItError.message("The selected input's PCM buffers did not match its audio format.")
    }
    pcmBuffer.frameLength = frameCount
    return try body(pcmBuffer)
}
