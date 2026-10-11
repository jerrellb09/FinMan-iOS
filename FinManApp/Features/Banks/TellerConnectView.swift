import SwiftUI
import WebKit

/// Teller Connect (bank picker + bank login, including OAuth) hosted in a web view.
/// Pass `enrollmentID` to repair an existing connection instead of adding a new one.
struct TellerConnectView: UIViewRepresentable {
    let config: TellerConfig
    var enrollmentID: String?
    let onSuccess: (BankLink) -> Void
    let onExit: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSuccess: onSuccess, onExit: onExit) }

    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "teller")
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))

        let container = UIView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        webView.pin(to: container)
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private var html: String {
        func js(_ value: String?) -> String {
            guard let value, let data = try? JSONEncoder().encode(value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html, body { margin: 0; background: transparent; }</style>
        </head><body>
        <script>
          const post = (type, payload) => window.webkit.messageHandlers.teller.postMessage({ type, payload: JSON.stringify(payload ?? null) });
          const script = document.createElement("script");
          script.src = "https://cdn.teller.io/connect/connect.js";
          script.onerror = () => post("failure", { message: "Couldn't load Teller Connect. Check your internet connection." });
          script.onload = () => {
            const options = {
              applicationId: \(js(config.applicationID)),
              environment: \(js(config.environment)),
              products: ["balance", "transactions"],
              onSuccess: enrollment => post("success", enrollment),
              onExit: () => post("exit"),
              onFailure: failure => post("failure", failure),
            };
            const enrollmentId = \(js(enrollmentID));
            if (enrollmentId) options.enrollmentId = enrollmentId;
            TellerConnect.setup(options).open();
          };
          document.head.appendChild(script);
        </script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        let onSuccess: (BankLink) -> Void
        let onExit: (String?) -> Void
        weak var container: UIView?
        private var popups: [WKWebView] = []
        private var finished = false

        init(onSuccess: @escaping (BankLink) -> Void, onExit: @escaping (String?) -> Void) {
            self.onSuccess = onSuccess
            self.onExit = onExit
        }

        private struct Enrollment: Decodable {
            struct Inner: Decodable {
                struct Institution: Decodable { let name: String }
                let id: String
                let institution: Institution
            }
            let accessToken: String
            let enrollment: Inner
        }
        private struct Failure: Decodable { let message: String? }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            let payload = Data(((body["payload"] as? String) ?? "null").utf8)
            switch type {
            case "success":
                guard let enrollment = try? JSONDecoder().decode(Enrollment.self, from: payload) else {
                    finish { $0.onExit("Teller sent an enrollment FinMan couldn't read.") }
                    return
                }
                let link = BankLink(id: enrollment.enrollment.id, institution: enrollment.enrollment.institution.name,
                                    accessToken: enrollment.accessToken)
                finish { $0.onSuccess(link) }
            case "failure":
                let failure = try? JSONDecoder().decode(Failure.self, from: payload)
                finish { $0.onExit(failure?.message ?? "Couldn't connect the bank.") }
            default:
                finish { $0.onExit(nil) }
            }
        }

        private func finish(_ action: (Coordinator) -> Void) {
            finished = true
            action(self)
        }

        // Some banks open their OAuth login in a new window; show it on top and close it when done.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let container else { return nil }
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.uiDelegate = self
            popup.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(popup)
            popup.pin(to: container)
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.removeFromSuperview()
            popups.removeAll { $0 === webView }
        }
    }
}

private extension UIView {
    func pin(to parent: UIView) {
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
