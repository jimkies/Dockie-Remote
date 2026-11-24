import UIKit

/// A decoded frame handed to the main actor. UIImage is immutable once made.
struct DecodedFrame: @unchecked Sendable {
    let session: Int
    let id: String
    let kind: FrameKind
    let at: Int64
    let image: UIImage
}

/// Decodes JPEG frames off the main thread, keeping only the newest frame waiting per account.
/// If decoding falls behind, older frames are overwritten before they are ever decoded.
actor FrameDecoder {
    private var pending: [String: (frame: Frame, session: Int)] = [:]
    private var draining = false
    private let deliver: @Sendable (DecodedFrame) async -> Void

    init(deliver: @escaping @Sendable (DecodedFrame) async -> Void) {
        self.deliver = deliver
    }

    /// `session` changes on every new pairing so frames from an old PC are dropped downstream.
    func submit(_ frame: Frame, session: Int) {
        if let waiting = pending[frame.id], waiting.session == session, waiting.frame.at > frame.at { return }
        pending[frame.id] = (frame, session)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    func reset() {
        pending.removeAll()
    }

    private func drain() async {
        while let (id, item) = pending.first {
            pending[id] = nil
            let frame = item.frame
            guard let data = Data(base64Encoded: frame.jpeg, options: .ignoreUnknownCharacters),
                  let image = UIImage(data: data)?.preparingForDisplay() else { continue }
            await deliver(DecodedFrame(session: item.session, id: frame.id, kind: frame.kind, at: frame.at, image: image))
        }
        draining = false
    }
}
