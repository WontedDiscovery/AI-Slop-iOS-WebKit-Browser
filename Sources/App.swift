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

// 書籤與歷史紀錄共用的資料型態
struct SavedLink: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
}

// 書籤與歷史紀錄，存在 UserDefaults
final class BrowserStore: ObservableObject {
    @Published private(set) var bookmarks: [SavedLink] = BrowserStore.load("bookmarks")
    @Published private(set) var history: [SavedLink] = BrowserStore.load("history")

    private static func load(_ key: String) -> [SavedLink] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([SavedLink].self, from: data) else { return [] }
        return items
    }

    private func save(_ items: [SavedLink], key: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    func toggleBookmark(title: String, url: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(SavedLink(title: title, url: url), at: 0)
        }
        save(bookmarks, key: "bookmarks")
    }

    func deleteBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save(bookmarks, key: "bookmarks")
    }

    func addHistory(title: String, url: String) {
        guard history.first?.url != url else { return }
        history.insert(SavedLink(title: title, url: url), at: 0)
        history = Array(history.prefix(300))
        save(history, key: "history")
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        save(history, key: "history")
    }

    func clearHistory() {
        history = []
        save(history, key: "history")
    }
}

// 單一分頁：一個 WKWebView 與它的導覽狀態
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let isPrivate: Bool
    let web: WKWebView
    var onOpenTab: ((BrowserTab) -> Void)?
    private let store: BrowserStore
    private var observers: [NSKeyValueObservation] = []

    @Published var address = ""
    @Published var title = "新分頁"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var desktopMode = false

    init(store: BrowserStore, isPrivate: Bool, configuration: WKWebViewConfiguration? = nil) {
        self.store = store
        self.isPrivate = isPrivate

        let config: WKWebViewConfiguration
        if let configuration {
            config = configuration
        } else {
            config = WKWebViewConfiguration()
            if isPrivate {
                config.websiteDataStore = .nonPersistent()
            }
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init()

        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true

        // 下拉重新整理
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        observers = [
            web.observe(\.title) { [weak self] wv, _ in self?.title = wv.title ?? "新分頁" },
            web.observe(\.url) { [weak self] wv, _ in
                self?.url = wv.url
                self?.address = wv.url?.absoluteString ?? ""
            },
            web.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            web.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            web.observe(\.estimatedProgress) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
            web.observe(\.isLoading) { [weak self] wv, _ in
                self?.isLoading = wv.isLoading
                if !wv.isLoading {
                    wv.scrollView.refreshControl?.endRefreshing()
                }
            }
        ]
    }

    // 下拉重新整理
    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        if web.url == nil {
            sender.endRefreshing()
        } else {
            web.reload()
        }
    }

    // 有網域就直接前往，否則用 Google 搜尋
    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var target: URL?
        if text.contains("://") {
            target = URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            target = URL(string: "https://" + text)
        } else {
            var comps = URLComponents(string: "https://www.google.com/search")
            comps?.queryItems = [URLQueryItem(name: "q", value: text)]
            target = comps?.url
        }
        if let target {
            web.load(URLRequest(url: target))
        }
    }

    func setDesktopMode(_ on: Bool) {
        desktopMode = on
        web.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isPrivate, let pageURL = webView.url else { return }
        store.addHistory(title: webView.title ?? pageURL.absoluteString, url: pageURL.absoluteString)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        decisionHandler(.allow, preferences)
    }

    // target="_blank" 的連結改為開新分頁
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = BrowserTab(store: store, isPrivate: isPrivate, configuration: configuration)
        onOpenTab?(tab)
        return tab.web
    }
}

// 管理所有分頁與目前選取的分頁
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    let store = BrowserStore()

    init() {
        addTab(url: "https://www.google.com")
    }

    var current: BrowserTab? {
        tabs.first(where: { $0.id == selectedID }) ?? tabs.last
    }

    func addTab(url: String? = nil, isPrivate: Bool = false) {
        let tab = BrowserTab(store: store, isPrivate: isPrivate)
        attach(tab)
        if let url {
            tab.go(url)
        }
    }

    func closeTabs(at offsets: IndexSet) {
        tabs.remove(atOffsets: offsets)
        if tabs.isEmpty {
            addTab()
        } else if !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs.last?.id
        }
    }

    func clearBrowsingData() {
        store.clearHistory()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    private func attach(_ tab: BrowserTab) {
        tab.onOpenTab = { [weak self] newTab in self?.attach(newTab) }
        tabs.append(tab)
        selectedID = tab.id
    }
}

struct ContentView: View {
    @StateObject var model = BrowserModel()

    var body: some View {
        if let tab = model.current {
            BrowserPage(model: model, tab: tab, store: model.store)
                .id(tab.id)
        }
    }
}

struct BrowserPage: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore

    @State var showTabs = false
    @State var showBookmarks = false
    @State var showHistory = false
    @FocusState var addressFocused = false

    private var currentURL: String {
        tab.url?.absoluteString ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ProgressView(value: tab.progress)
                .opacity(tab.isLoading ? 1 : 0)
            WebViewRepresentable(webView: tab.web)
            bottomBar
        }
        .preferredColorScheme(tab.isPrivate ? .dark : nil)
        .sheet(isPresented: $showTabs) {
            TabsSheet(isPresented: $showTabs, model: model)
        }
        .sheet(isPresented: $showBookmarks) {
            LinkListSheet(isPresented: $showBookmarks, title: "書籤", links: store.bookmarks,
                          onOpen: { tab.go($0) }, onDelete: store.deleteBookmarks)
        }
        .sheet(isPresented: $showHistory) {
            LinkListSheet(isPresented: $showHistory, title: "歷史紀錄", links: store.history,
                          onOpen: { tab.go($0) }, onDelete: store.deleteHistory)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    tab.web.pageZoom = min(tab.web.pageZoom + 0.1, 2)
                } label: {
                    Label("放大文字", systemImage: "textformat.size.larger")
                }
                Button {
                    tab.web.pageZoom = max(tab.web.pageZoom - 0.1, 0.5)
                } label: {
                    Label("縮小文字", systemImage: "textformat.size.smaller")
                }
                Button {
                    tab.setDesktopMode(!tab.desktopMode)
                } label: {
                    Label(tab.desktopMode ? "請求行動版網站" : "請求桌面版網站",
                          systemImage: "desktopcomputer")
                }
            } label: {
                Text("aA").font(.system(size: 15, weight: .semibold))
            }

            HStack(spacing: 4) {
                if tab.url?.scheme == "https" {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("搜尋或輸入網址", text: $tab.address)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        tab.go(tab.address)
                        addressFocused = false
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))

            if addressFocused {
                Button("取消") {
                    addressFocused = false
                    tab.address = currentURL
                }
            } else {
                Button {
                    if tab.isLoading {
                        tab.web.stopLoading()
                    } else {
                        tab.web.reload()
                    }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack {
            Button { tab.web.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.web.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!tab.canGoForward)
            Spacer()
            shareButton
            Spacer()
            Button { showBookmarks = true } label: {
                Image(systemName: "book")
            }
            Spacer()
            Button { showTabs = true } label: {
                Image(systemName: "square.on.square")
                    .overlay(Text("\(model.tabs.count)").font(.system(size: 11, weight: .bold)))
            }
            Spacer()
            moreMenu
        }
        .font(.system(size: 19))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = tab.url {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { model.addTab() } label: {
                Label("新增分頁", systemImage: "plus.square")
            }
            Button { model.addTab(isPrivate: true) } label: {
                Label("新增私密分頁", systemImage: "eye.slash")
            }
            if !currentURL.isEmpty {
                Button {
                    store.toggleBookmark(title: tab.title, url: currentURL)
                } label: {
                    Label(store.isBookmarked(currentURL) ? "移除書籤" : "加入書籤",
                          systemImage: store.isBookmarked(currentURL) ? "bookmark.slash" : "bookmark")
                }
            }
            Button { showHistory = true } label: {
                Label("歷史紀錄", systemImage: "clock")
            }
            Divider()
            Button(role: .destructive) {
                model.clearBrowsingData()
            } label: {
                Label("清除瀏覽資料", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

struct TabsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: BrowserModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.tabs) { tab in
                    Button {
                        model.selectedID = tab.id
                        isPresented = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title).lineLimit(1)
                                Text(tab.url?.host ?? "新分頁")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if tab.isPrivate {
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.secondary)
                            }
                            if tab.id == model.selectedID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                .onDelete(perform: model.closeTabs)
            }
            .navigationTitle("分頁（\(model.tabs.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        model.addTab()
                        isPresented = false
                    } label: {
                        Label("新增分頁", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }
}

struct LinkListSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let links: [SavedLink]
    let onOpen: (String) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            List {
                if links.isEmpty {
                    Text("目前沒有項目").foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    Button {
                        onOpen(link.url)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title).lineLimit(1)
                            Text(link.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: onDelete)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
