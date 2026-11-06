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

// MARK: - Liquid Glass（iOS 26 以上使用；較舊系統退回半透明材質）

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(glassStyle(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

@available(iOS 26.0, *)
private func glassStyle(tint: Color?, interactive: Bool) -> Glass {
    var style: Glass = .regular
    if let tint {
        style = style.tint(tint)
    }
    if interactive {
        style = style.interactive()
    }
    return style
}

@ViewBuilder
func liquidGlassGroup<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    } else {
        content()
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
    @Published var snapshot: UIImage?

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
        // 網頁延伸到螢幕上下邊緣，這裡留出頂部與底部膠囊的空間，內容不會被遮住
        web.scrollView.contentInset = UIEdgeInsets(top: 64, left: 0, bottom: 72, right: 0)

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

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        if web.url == nil {
            sender.endRefreshing()
        } else {
            web.reload()
        }
    }

    // 擷取目前畫面，作為分頁總覽的預覽圖
    func captureSnapshot() {
        guard url != nil else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 360)
        web.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
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
    @Published var showOverview = false
    let store = BrowserStore()

    init() {
        addTab(url: "https://www.google.com")
    }

    var current: BrowserTab? {
        tabs.first(where: { $0.id == selectedID }) ?? tabs.last
    }

    @discardableResult
    func addTab(url: String? = nil, isPrivate: Bool = false) -> BrowserTab {
        let tab = BrowserTab(store: store, isPrivate: isPrivate)
        attach(tab)
        if let url {
            tab.go(url)
        }
        return tab
    }

    // 關閉分頁，卡片會以動畫移除
    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tabs.remove(at: index)
            if tabs.isEmpty {
                addTab()
            } else if !tabs.contains(where: { $0.id == selectedID }) {
                selectedID = tabs.last?.id
            }
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
                .transition(.opacity)
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
    @FocusState var addressFocused: Bool

    init(model: BrowserModel, tab: BrowserTab, store: BrowserStore) {
        _model = ObservedObject(wrappedValue: model)
        _tab = ObservedObject(wrappedValue: tab)
        _store = ObservedObject(wrappedValue: store)
    }

    private var currentURL: String {
        tab.url?.absoluteString ?? ""
    }

    private var displayHost: String {
        guard let host = tab.url?.host else { return "搜尋或輸入網址" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        ZStack {
            ZStack {
                WebViewRepresentable(webView: tab.web)
                if tab.url == nil {
                    startPage
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .opacity(tab.isLoading ? 1 : 0)
                    .allowsHitTesting(false)
                Spacer()
            }

            VStack(spacing: 0) {
                Spacer()
                bottomBar
            }
        }
        .preferredColorScheme(tab.isPrivate ? .dark : nil)
        .fullScreenCover(isPresented: $showTabs) {
            TabOverview(isPresented: $showTabs, model: model, store: store)
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

    // 頂部浮動膠囊：選單、網址與重新整理
    private var topBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { _ = model.addTab() }
                } label: {
                    Label("新增分頁", systemImage: "plus.square")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { _ = model.addTab(isPrivate: true) }
                } label: {
                    Label("新增私密分頁", systemImage: "eye.slash")
                }
                Divider()
                if !currentURL.isEmpty {
                    Button {
                        store.toggleBookmark(title: tab.title, url: currentURL)
                    } label: {
                        Label(store.isBookmarked(currentURL) ? "移除書籤" : "加入書籤",
                              systemImage: store.isBookmarked(currentURL) ? "bookmark.slash" : "bookmark")
                    }
                }
                Button {
                    showHistory = true
                } label: {
                    Label("歷史紀錄", systemImage: "clock")
                }
                Divider()
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
                    Label(tab.desktopMode ? "請求行動版網站" : "請求桌面版網站", systemImage: "desktopcomputer")
                }
                Divider()
                Button(role: .destructive) {
                    model.clearBrowsingData()
                } label: {
                    Label("清除瀏覽資料", systemImage: "trash")
                }
            } label: {
                symbolImage("line.3.horizontal")
            }
            .buttonStyle(.plain)

            ZStack {
                Text(displayHost)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .opacity(addressFocused ? 0 : 1)
                    .allowsHitTesting(false)
                TextField("搜尋或輸入網址", text: $tab.address)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .opacity(addressFocused ? 1 : 0)
                    .onSubmit {
                        tab.go(tab.address)
                        addressFocused = false
                    }
            }
            .frame(maxWidth: .infinity)

            Button {
                if addressFocused {
                    addressFocused = false
                    tab.address = currentURL
                } else if tab.isLoading {
                    tab.web.stopLoading()
                } else {
                    tab.web.reload()
                }
            } label: {
                symbolImage(addressFocused || tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .liquidGlass(in: Capsule())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // 底部浮動膠囊：上一頁、下一頁、分享、書籤與分頁
    private var bottomBar: some View {
        HStack {
            navButton("chevron.backward") { tab.web.goBack() }
                .disabled(!tab.canGoBack)
            Spacer()
            navButton("chevron.forward") { tab.web.goForward() }
                .disabled(!tab.canGoForward)
            Spacer()
            shareButton
            Spacer()
            navButton("book") { showBookmarks = true }
            Spacer()
            navButton("square.on.square") {
                tab.captureSnapshot()
                showTabs = true
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 60)
        .liquidGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    // 空白分頁顯示的起始頁（喜好項目）
    private var startPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("喜好項目").font(.title3.bold())
            if store.bookmarks.isEmpty {
                Text("加入書籤後會顯示在這裡").font(.footnote).foregroundStyle(.secondary)
            }
            FavoritesGrid(links: store.bookmarks, iconSize: 60) { tab.go($0) }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 130)
        .padding(.bottom, 110)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = tab.url {
            ShareLink(item: url) {
                symbolImage("square.and.arrow.up")
            }
        } else {
            symbolImage("square.and.arrow.up")
                .foregroundStyle(.secondary)
        }
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            symbolImage(icon)
        }
        .buttonStyle(.plain)
    }

    private func symbolImage(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

// 分頁總覽：2 欄卡片，新增與關閉都有動畫
struct TabOverview: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: BrowserModel
    @ObservedObject var store: BrowserStore
    @State var privateMode = false

    init(isPresented: Binding<Bool>, model: BrowserModel, store: BrowserStore) {
        _isPresented = isPresented
        _model = ObservedObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: store)
    }

    private var visibleTabs: [BrowserTab] {
        model.tabs.filter { $0.isPrivate == privateMode }
    }

    private var normalCount: Int {
        model.tabs.filter { !$0.isPrivate }.count
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    if visibleTabs.isEmpty {
                        Text(privateMode ? "沒有私密分頁" : "沒有標籤頁")
                            .foregroundStyle(.secondary)
                            .padding(.top, 120)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                              spacing: 22) {
                        ForEach(visibleTabs) { tab in
                            TabCard(tab: tab, favorites: store.bookmarks, onSelect: {
                                model.selectedID = tab.id
                                isPresented = false
                            }, onClose: {
                                model.closeTab(tab)
                            })
                            .id(tab.id)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 120)
                }
                bottomBar(proxy)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        }
    }

    private func bottomBar(_ proxy: ScrollViewProxy) -> some View {
        liquidGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        _ = model.addTab(isPrivate: privateMode)
                    }
                    if let id = visibleTabs.last?.id {
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)

                HStack(spacing: 0) {
                    segment("私密瀏覽", isOn: privateMode) { privateMode = true }
                    segment("\(normalCount) 個標籤頁", isOn: !privateMode) { privateMode = false }
                }
                .padding(4)
                .liquidGlass(in: Capsule(), interactive: true)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "checkmark")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .liquidGlass(in: Circle(), tint: .blue, interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func segment(_ title: String, isOn: Bool, select: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { select() }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(isOn ? Color.primary.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// 單一分頁卡片：預覽圖、右上角關閉按鈕與標題
struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let favorites: [SavedLink]
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            HStack(spacing: 6) {
                Image(systemName: tab.url == nil ? "square.grid.2x2" : "globe")
                Text(tab.title).lineLimit(1)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = tab.snapshot {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if tab.url == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("喜好項目").font(.caption.bold())
                FavoritesGrid(links: favorites, iconSize: 36) { _ in }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemBackground))
        } else {
            Text(tab.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

// 喜好項目網格：以網站名稱的第一個字作為圖示
struct FavoritesGrid: View {
    let links: [SavedLink]
    let iconSize: CGFloat
    let onOpen: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
            ForEach(links.prefix(8)) { link in
                Button {
                    onOpen(link.url)
                } label: {
                    VStack(spacing: 4) {
                        Text(String(link.title.prefix(1)))
                            .font(.system(size: iconSize * 0.45, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: iconSize, height: iconSize)
                            .background(Color.gray.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                        Text(link.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
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
