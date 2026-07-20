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

    /// Open the containing app via the `whatsub://` scheme.
    ///
    /// Two-step, in this order:
    ///  1. `NSExtensionContext.open` — the official API. Apple only DOCUMENTS
    ///     it for the Today extension point; from a Share Extension it often
    ///     calls back `false` and does nothing, which is why step 2 exists.
    ///  2. Responder-chain `perform("openURL:")` — the long-standing
    ///     workaround, used ONLY when step 1 reported failure.
    ///
    /// History (2026-07-20): step 2 was REMOVED in 042058d while fixing the
    /// "YouTube frozen ~30s after returning" bug, on the assumption that
    /// `ctx.open` alone suffices. It doesn't — auto-launch regressed to
    /// "nothing happens, user must switch apps manually". That fix bundled
    /// three changes; the other two (start the open in `viewDidAppear` once
    /// presentation finished + await `completeRequest` teardown) are the ones
    /// that plausibly cured the freeze, since both addressed our view
    /// lingering in the host's hierarchy. Step 2 is restored on top of them,
    /// and now runs strictly AFTER `ctx.open` declined rather than racing it.
    ///
    /// ⚠️ If the YouTube freeze reappears on device, this fallback is the
    /// culprit — drop it again and switch to a tap-to-open confirmation UI
    /// inside the extension instead of auto-launching.
    ///
    /// Either way the URL is already in the App Group, so the main app's
    /// scenePhase safety-net still imports it whenever the user next opens
    /// whatSub — auto-launch is a convenience layer, never the only path.
    @discardableResult
    private func openHostApp() async -> Bool {
        guard let url = URL(string: "whatsub://import") else { return false }
        if let ctx = extensionContext {
            let opened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                ctx.open(url) { cont.resume(returning: $0) }
            }
            if opened { return true }
        }
        // Skip our own VC: `UIViewController` responds to openURL: only via
        // the chain above it, and performing it on self would recurse.
        var responder: UIResponder? = self.next
        let selector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }
}
