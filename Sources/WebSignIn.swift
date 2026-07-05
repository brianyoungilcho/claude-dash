import AppKit
import WebKit

/// An in-app claude.ai login window that captures the sessionKey cookie
/// automatically — no DevTools digging. Uses a NON-PERSISTENT data store so
/// each sign-in is isolated: nothing carries over between accounts and the
/// cookie jar evaporates when the window closes. The key goes only to the
/// caller (which stores it in the Keychain).
@MainActor
final class SignInWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private static var active: SignInWindow?

    private var window: NSWindow?
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var onKey: ((String) -> Void)?
    private var captured = false

    static func present(onKey: @escaping (String) -> Void) {
        // Single instance: a second Sign in… click supersedes the first login
        // window — tear the old one down PROPERLY (timer invalidated, window
        // closed) instead of silently dropping its last strong reference.
        active?.close()
        let controller = SignInWindow()
        controller.onKey = onKey
        active = controller
        controller.show()
    }

    private func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Some identity providers refuse obvious embedded webviews; a desktop
        // Safari UA keeps the normal login flows working.
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let win = NSWindow(contentRect: webView.frame,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Sign in to Claude"
        win.contentView = webView
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // The sessionKey cookie appears once login completes; poll for it so
        // we catch flows that finish without a full navigation (SPA logins).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkForKey() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForKey()
    }

    private func checkForKey() {
        guard !captured else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.captured else { return }
            if let key = cookies.first(where: {
                $0.name == "sessionKey" && $0.domain.contains("claude.ai") && $0.value.hasPrefix("sk-ant-")
            })?.value {
                self.captured = true
                self.onKey?(key)
                self.close()
            }
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        window?.close()
        if SignInWindow.active === self { SignInWindow.active = nil }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        if SignInWindow.active === self { SignInWindow.active = nil }
    }
}
