import UIKit
import UniformTypeIdentifiers

/// Share-extension entry. Pulls the shared URL out of the input items, stashes
/// it in the App Group, opens the host app via `whatsub://import`, and finishes.
/// No UI — completes immediately.
class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear, not viewDidLoad: kicking off the host-app open while
        // our extension VC is still presenting leaves a zombie view in the
        // host app on iOS 16+ — YouTube has been seen to lock up touch
        // handling for ~30s on return until iOS GCs the orphan.
        guard !didStart else { return }
        didStart = true
        Task { await handleShare() }
    }

    private func handleShare() async {
        let urlString = await extractSharedURL()
        if let urlString {
            AppGroup.setPendingImportURL(urlString)
            await openHostApp()
        }
        // completeRequest WITH completion handler — the no-arg form lets iOS
        // resume the host app before our view controller is fully torn down,
        // so our (clear) view ends up sitting on top of the host's hierarchy
        // eating touches. The continuation guarantees we wait for teardown.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            extensionContext?.completeRequest(returningItems: nil) { _ in
                cont.resume()
            }
        }
    }

    /// Read a URL (public.url) or text containing a URL from the input items.
    private func extractSharedURL() async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let obj = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = obj as? URL {
                    return url.absoluteString
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let obj = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let text = obj as? String, let u = firstURL(in: text) {
                    return u
                }
            }
        }
        return nil
    }

    /// Open the containing app via the `whatsub://` scheme. iOS routes the
    /// scheme to whatSub. If the system declines (some iOS versions return
    /// false mid-share-sheet-dismiss), the URL is still saved to the App
    /// Group and the main app's scenePhase safety-net picks it up on next
    /// launch — we deliberately do NOT fall back to the responder-chain
    /// `perform("openURL:")` hack, which has been a root cause of host-app
    /// (YouTube) UI lockups on iOS 16+.
    @discardableResult
    private func openHostApp() async -> Bool {
        guard let url = URL(string: "whatsub://import"), let ctx = extensionContext else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ctx.open(url) { cont.resume(returning: $0) }
        }
    }
}
