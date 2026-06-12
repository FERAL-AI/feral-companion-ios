import Foundation
import SwiftUI
import UIKit

/// Real `ChatStore`. Surfaces messages from the BrainClient transcript
/// and exposes a `send` action that pipes user text to the brain.
@MainActor
public final class ChatStore: ObservableObject {

    @Published public private(set) var messages: [BrainMessage] = []
    @Published public var draft: String = ""
    /// Image the user attached in the composer, sent with the next
    /// `send()` via the brain's vision_ask path. Cleared on send.
    @Published public var pendingImage: UIImage? = nil
    @Published public private(set) var sending: Bool = false

    private weak var brainClient: BrainClient?
    private var observation: Task<Void, Never>?

    public init() {}

    /// Bind to a `BrainClient` so `messages` mirrors its transcript.
    public func bind(to client: BrainClient) {
        brainClient = client
        observation?.cancel()
        observation = Task { [weak self] in
            // Lightweight polling is fine here — BrainClient.transcript
            // is a Published @MainActor property; we just want to
            // mirror it onto our published store. Using @Published
            // forwarding via Combine would be cleaner; this is the
            // minimum that works without adding another framework.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let bc = self.brainClient else { return }
                let latest = bc.transcript
                if self.messages.count != latest.count {
                    self.messages = latest
                }
            }
        }
    }

    public func send() async {
        guard let bc = brainClient else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil else { return }
        sending = true
        defer { sending = false }
        do {
            if let image {
                // Brain's chat_request denies empty text, so image-only
                // sends get a sensible default prompt.
                let prompt = text.isEmpty ? "What do you see in this image?" : text
                guard let encoded = ChatImageEncoder.encodeForBrain(image) else {
                    appendSystemMessage("Couldn't process that image — try a smaller one.")
                    return
                }
                try await bc.sendChat(
                    prompt,
                    imageJPEG: encoded.data,
                    width: encoded.width,
                    height: encoded.height
                )
                pendingImage = nil
            } else {
                try await bc.sendChat(text)
            }
            draft = ""
        } catch {
            // Surface as a system message so the user can see why nothing happened.
            appendSystemMessage("Send failed: \(error.localizedDescription)")
        }
    }

    /// Public helper for views that want to surface non-brain messages
    /// (errors, voice-pipeline failures) without having to reach into
    /// the published `messages` directly.
    public func appendSystemMessage(_ text: String) {
        messages.append(BrainMessage(role: .system, text: text))
    }
}

/// Downscale + JPEG-encode a picked image so it fits the brain's
/// `video_frame` cap (512 KiB of base64 — HUP error 4020 drops
/// anything bigger; see `feral-core/api/server.py:VIDEO_FRAME_MAX_BYTES`).
enum ChatImageEncoder {
    /// Headroom below the brain's 512 KiB base64 cap.
    static let maxBase64Bytes = 500 * 1024
    static let maxLongEdge: CGFloat = 1280

    static func encodeForBrain(_ image: UIImage) -> (data: Data, width: Int, height: Int)? {
        var candidate = downscaled(image, maxLongEdge: maxLongEdge)
        // Step quality down first, then halve resolution as a last resort.
        for longEdge in [maxLongEdge, maxLongEdge / 2] {
            for quality in [0.7, 0.5, 0.35] {
                guard let data = candidate.jpegData(compressionQuality: quality) else { continue }
                // base64 size without materialising the string.
                if (data.count + 2) / 3 * 4 <= maxBase64Bytes {
                    return (data, Int(candidate.size.width), Int(candidate.size.height))
                }
            }
            candidate = downscaled(candidate, maxLongEdge: longEdge / 2)
        }
        return nil
    }

    private static func downscaled(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let scale = maxLongEdge / longEdge
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
