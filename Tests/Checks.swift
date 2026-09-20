import Foundation

@main
struct Checks {
    static func main() throws {
        checkAudioConversion()
        checkRingBuffer()
        try checkImports()
        let localCount = CompletionCount()
        let local = PlaybackCompletion(remaining: 1) { localCount.increment() }
        precondition(localCount.value == 0)
        local.markFinished()
        precondition(localCount.value == 1, "Local playback must complete after its callback")

        let dualCount = CompletionCount()
        let dual = PlaybackCompletion(remaining: 2) { dualCount.increment() }
        dual.markFinished()
        precondition(dualCount.value == 0, "Wait for both outputs")
        dual.markFinished()
        precondition(dualCount.value == 1)

        for _ in 0..<100 {
            let count = CompletionCount()
            let completion = PlaybackCompletion(remaining: 2) { count.increment() }
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                completion.markFinished()
            }
            precondition(count.value == 1, "Concurrent outputs must complete exactly once")
        }

        precondition(" \n\t".nilIfBlank == nil)
        precondition("  Custom label \n".nilIfBlank == "Custom label")
        precondition(AudioFileSupport.cleanEmoji(" \n") == nil)
        precondition(AudioFileSupport.cleanEmoji("  👩🏽‍💻🎵 ") == "👩🏽‍💻", "Keep one whole grapheme")
        precondition(AudioFileSupport.cleanEmoji("  AB ") == "A")
        precondition(AudioFileSupport.supportedExtensions.contains("wav"))
        precondition(!AudioFileSupport.supportedExtensions.contains("json"))
        let error = NSError(domain: "MicRelayCheck", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unreadable file"
        ])
        precondition(AudioFileSupport.playbackErrorMessage(error) == "Unreadable file")
        print("Playback completion and file-label checks passed.")
    }
}

private final class CompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
