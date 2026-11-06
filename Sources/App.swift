import SwiftUI
import WebKit

@main
struct BrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// 瀏覽器核心：WKWebView（WebKit）+ 導覽狀態
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web = WKWebView()
    @Published var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0
    private var observers: [NSKeyValueObservation] = []

    override init() {
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true

        observers = [
            web.observe(\.canGoBack) { [weak self] wv, _ in
                self?.canGoBack = wv.canGoBack
            },
            web.observe(\.canGoForward) { [weak self] wv, _ in
                self?.canGoForward = wv.canGoForward
            },
            web.observe(\.estimatedProgress) { [weak self] wv, _ in
                self?.progress = wv.estimatedProgress
            },
            web.observe(\.url) { [weak self] wv, _ in
                self?.address = wv.url?.absoluteString ?? ""
            }
        ]
        load("https://www.google.com")
    }

    // 有網域就直接前往，否則用 Google 搜尋
    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var url: URL?
        if text.contains("://") {
            url = URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            url = URL(string: "https://" + text)
        } else {
            var comps = URLComponents(string: "https://www.google.com/search")
            comps?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = comps?.url
        }
        if let url {
            web.load(URLRequest(url: url))
        }
    }

    // target="_blank" 的連結改在同一頁開啟
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { browser.web.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!browser.canGoBack)

                Button { browser.web.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!browser.canGoForward)

                TextField("搜尋或輸入網址", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.load(browser.address)
                        addressFocused = false
                    }

                Button { browser.web.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(10)

            ProgressView(value: browser.progress)
                .opacity(browser.progress < 1 ? 1 : 0)

            WebViewRepresentable(webView: browser.web)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
