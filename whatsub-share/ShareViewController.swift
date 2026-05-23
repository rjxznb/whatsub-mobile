import UIKit
import UniformTypeIdentifiers

/// Share-extension entry. Pulls the shared URL out of the input items, stashes
/// it in the App Group, opens the host app via `whatsub://import`, and finishes.
/// No UI — completes immediately.
class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handleShare() }
    }

    private func handleShare() async {
        let urlString = await extractSharedURL()
        if let urlString {
            AppGroup.setPendingImportURL(urlString)
            await openHostApp()
        }
        // Complete AFTER the open is initiated, so the share sheet doesn't
        // dismiss + cancel the pending launch.
        extensionContext?.completeRequest(returningItems: nil)
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
    /// 1) Official API: ask the HOST app (e.g. YouTube) to open our URL — iOS
    ///    then routes the scheme to whatSub. Works on most modern iOS.
    /// 2) Fallback: responder-chain `openURL:` (works on some older versions).
    /// Either way the URL is already saved to the App Group, so the main app's
    /// scenePhase safety-net picks it up even if neither auto-launches.
    @discardableResult
    private func openHostApp() async -> Bool {
        guard let url = URL(string: "whatsub://import") else { return false }
        if let ctx = extensionContext {
            let opened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                ctx.open(url) { cont.resume(returning: $0) }
            }
            if opened { return true }
        }
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: selector) && !(r is ShareViewController) {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }
}
