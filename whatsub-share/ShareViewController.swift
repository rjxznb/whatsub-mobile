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
            openHostApp()
        }
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

    /// Open the containing app via the custom scheme by walking the responder
    /// chain to UIApplication (extensions can't call UIApplication.shared).
    private func openHostApp() {
        guard let url = URL(string: "whatsub://import") else { return }
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: selector) && !(r is ShareViewController) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }
}
