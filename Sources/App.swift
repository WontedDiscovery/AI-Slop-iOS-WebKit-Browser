import SwiftUI
import WebKit
import UIKit

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

// MARK: - 設定與搜尋引擎

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, bing, duckduckgo, yahoo, baidu

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        case .yahoo: return "Yahoo"
        case .baidu: return "百度"
        }
    }

    func searchURL(_ query: String) -> URL? {
        let base: String
        let key: String
        switch self {
        case .google: base = "https://www.google.com/search"; key = "q"
        case .bing: base = "https://www.bing.com/search"; key = "q"
        case .duckduckgo: base = "https://duckduckgo.com/"; key = "q"
        case .yahoo: base = "https://search.yahoo.com/search"; key = "p"
        case .baidu: base = "https://www.baidu.com/s"; key = "wd"
        }
        var comps = URLComponents(string: base)
        comps?.queryItems = [URLQueryItem(name: key, value: query)]
        return comps?.url
    }

    func suggestURL(_ query: String) -> URL? {
        var comps: URLComponents?
        switch self {
        case .google, .yahoo:
            comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            comps?.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        case .bing:
            comps = URLComponents(string: "https://api.bing.com/osjson.aspx")
            comps?.queryItems = [URLQueryItem(name: "query", value: query)]
        case .duckduckgo:
            comps = URLComponents(string: "https://duckduckgo.com/ac/")
            comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        case .baidu:
            comps = URLComponents(string: "https://suggestion.baidu.com/su")
            comps?.queryItems = [URLQueryItem(name: "wd", value: query), URLQueryItem(name: "action", value: "opensearch")]
        }
        return comps?.url
    }

    // 各家建議 API 的格式不同：["q",["a","b"]] 或 [{"phrase":"a"}]
    static func parseSuggestions(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let arr = json as? [Any], arr.count > 1, let list = arr[1] as? [String] {
            return list
        }
        if let arr = json as? [[String: Any]] {
            return arr.compactMap { $0["phrase"] as? String }
        }
        return []
    }
}

enum Prefs {
    static func bool(_ key: String, default value: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? value
    }

    static var blockPopups: Bool { bool("blockPopups", default: true) }
    static var javaScriptEnabled: Bool { bool("javaScriptEnabled", default: true) }
    static var blockTrackers: Bool { bool("blockTrackers", default: true) }
    static var showSuggestions: Bool { bool("showSuggestions", default: true) }

    static var engine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
    }
}

// MARK: - 共用工具

func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

func presentShare(_ items: [Any]) {
    guard let top = topViewController() else { return }
    top.present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
}

func presentAlert(title: String?, message: String) {
    guard let top = topViewController() else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    top.present(alert, animated: true)
}

func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - 廣告與追蹤器封鎖（內容阻擋規則）

enum ContentBlocker {
    static var ruleList: WKContentRuleList?

    private static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "adnxs.com", "taboola.com", "outbrain.com",
        "criteo.com", "scorecardresearch.com", "hotjar.com", "adsystem.com",
        "amazon-adsystem.com", "moatads.com", "pubmatic.com", "rubiconproject.com"
    ]

    private static var encodedRules: String {
        let rules: [[String: Any]] = domains.map { domain -> [String: Any] in
            let pattern = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": pattern, "load-type": ["third-party"]],
                "action": ["type": "block"]
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func compile(completion: @escaping () -> Void) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "tracker-rules",
            encodedContentRuleList: encodedRules
        ) { list, _ in
            DispatchQueue.main.async {
                ruleList = list
                completion()
            }
        }
    }

    static func apply(to web: WKWebView, enabled: Bool) {
        guard let list = ruleList else { return }
        web.configuration.userContentController.remove(list)
        if enabled {
            web.configuration.userContentController.add(list)
        }
    }
}

// MARK: - 資料型態與儲存

// 書籤、閱讀清單與歷史紀錄共用的資料型態
struct SavedLink: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
    var favorite = false

    enum CodingKeys: String, CodingKey {
        case id, title, url, date, favorite
    }

    init(title: String, url: String, favorite: Bool = false) {
        self.title = title
        self.url = url
        self.favorite = favorite
    }

    // 相容舊版資料（沒有 date / favorite 欄位；舊書籤視為喜好項目）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? true
    }
}

// 書籤、閱讀清單與歷史紀錄，存在 UserDefaults
final class BrowserStore: ObservableObject {
    enum Kind {
        case bookmarks, history, reading
    }

    @Published private(set) var bookmarks: [SavedLink] = BrowserStore.load("bookmarks")
    @Published private(set) var history: [SavedLink] = BrowserStore.load("history")
    @Published private(set) var readingList: [SavedLink] = BrowserStore.load("readingList")

    var favorites: [SavedLink] {
        bookmarks.filter { $0.favorite }
    }

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
        bookmarks.contains(where: { $0.url == url })
    }

    func toggleBookmark(title: String, url: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(SavedLink(title: title, url: url), at: 0)
        }
        save(bookmarks, key: "bookmarks")
    }

    func addFavorite(title: String, url: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks[index].favorite = true
        } else {
            bookmarks.insert(SavedLink(title: title, url: url, favorite: true), at: 0)
        }
        save(bookmarks, key: "bookmarks")
    }

    func toggleFavorite(_ id: UUID) {
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].favorite.toggle()
            save(bookmarks, key: "bookmarks")
        }
    }

    func addReading(title: String, url: String) {
        if readingList.contains(where: { $0.url == url }) { return }
        readingList.insert(SavedLink(title: title, url: url), at: 0)
        save(readingList, key: "readingList")
    }

    func remove(_ id: UUID, kind: Kind) {
        switch kind {
        case .bookmarks:
            bookmarks.removeAll { $0.id == id }
            save(bookmarks, key: "bookmarks")
        case .history:
            history.removeAll { $0.id == id }
            save(history, key: "history")
        case .reading:
            readingList.removeAll { $0.id == id }
            save(readingList, key: "readingList")
        }
    }

    func addHistory(title: String, url: String) {
        guard history.first?.url != url else { return }
        history.insert(SavedLink(title: title, url: url), at: 0)
        history = Array(history.prefix(500))
        save(history, key: "history")
    }

    func clearHistory() {
        history = []
        save(history, key: "history")
    }
}

// MARK: - 下載管理

struct DownloadItem: Identifiable {
    enum State {
        case running, finished, failed
    }

    let id = UUID()
    var name: String
    var fileURL: URL?
    var progress: Double = 0
    var state: State = .running
}

final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    @Published var items: [DownloadItem] = []
    @Published var banner: String?

    private var active: [ObjectIdentifier: (download: WKDownload, id: UUID)] = [:]
    private var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var bannerToken = UUID()

    private static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }

    private override init() {
        super.init()
        // 載入先前下載過、仍在 App 資料夾內的檔案
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: DownloadManager.folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let sorted = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        items = sorted.map { url in
            var item = DownloadItem(name: url.lastPathComponent)
            item.fileURL = url
            item.progress = 1
            item.state = .finished
            return item
        }
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let rawName = download.originalRequest?.url?.lastPathComponent ?? ""
        let item = DownloadItem(name: rawName.isEmpty ? "下載項目" : rawName)
        items.insert(item, at: 0)
        let key = ObjectIdentifier(download)
        active[key] = (download: download, id: item.id)
        let itemID = item.id
        observers[key] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.update(itemID) { $0.progress = value }
            }
        }
        show("正在下載 \(item.name)")
    }

    func remove(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), let url = item.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == id }
    }

    func removeAll() {
        for item in items where item.state != .running {
            if let url = item.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        items.removeAll { $0.state != .running }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            change(&items[index])
        }
    }

    private func show(_ text: String) {
        banner = text
        let token = UUID()
        bannerToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.bannerToken == token {
                self?.banner = nil
            }
        }
    }

    private func finish(_ download: WKDownload, success: Bool) {
        let key = ObjectIdentifier(download)
        if let entry = active[key] {
            update(entry.id) {
                $0.state = success ? .finished : .failed
                if success { $0.progress = 1 }
            }
            if let item = items.first(where: { $0.id == entry.id }) {
                show(success ? "已下載 \(item.name)" : "下載失敗 \(item.name)")
            }
        }
        observers[key]?.invalidate()
        observers[key] = nil
        active[key] = nil
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let dir = DownloadManager.folder
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let original = suggestedFilename.isEmpty ? "下載項目" : suggestedFilename
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var destination = dir.appendingPathComponent(original)
        var counter = 1
        while fm.fileExists(atPath: destination.path) {
            counter += 1
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            destination = dir.appendingPathComponent(name)
        }

        if let entry = active[ObjectIdentifier(download)] {
            let finalName = destination.lastPathComponent
            update(entry.id) {
                $0.name = finalName
                $0.fileURL = destination
            }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, success: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, success: false)
    }
}

// MARK: - 單一分頁

// 單一分頁：一個 WKWebView 與它的導覽狀態
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    static let errorTitle = "無法開啟網頁"

    // 所有私密分頁共用同一個暫存資料庫；全部關閉後會重建
    static var privateDataStore = WKWebsiteDataStore.nonPersistent()

    let id = UUID()
    let isPrivate: Bool
    let web: WKWebView
    var onOpenTab: ((BrowserTab) -> Void)?
    var onClose: ((BrowserTab) -> Void)?
    var onNavigated: (() -> Void)?
    var pendingURL: URL?
    private let store: BrowserStore
    private var observers: [NSKeyValueObservation] = []
    private var lastOffsetY: CGFloat = 0
    private var readerLoading = false
    private var readerOriginalURL: URL?

    @Published var address = ""
    @Published var title = "新分頁"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var desktopMode = false
    @Published var snapshot: UIImage?
    @Published var isSecure = false
    @Published var barsCollapsed = false
    @Published var isReader = false
    @Published var pageZoom: CGFloat = 1

    init(store: BrowserStore, isPrivate: Bool, configuration: WKWebViewConfiguration? = nil) {
        self.store = store
        self.isPrivate = isPrivate

        let config: WKWebViewConfiguration
        if let configuration {
            config = configuration
        } else {
            config = WKWebViewConfiguration()
            if isPrivate {
                config.websiteDataStore = BrowserTab.privateDataStore
            }
            config.allowsInlineMediaPlayback = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = !Prefs.blockPopups
            // 讓網站把這個瀏覽器當成 Safari（例如 Google 登入）
            config.applicationNameForUserAgent = "Version/17.5 Mobile/15E148 Safari/604.1"
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init()

        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isFindInteractionEnabled = true
        // 網頁延伸到螢幕上下邊緣，這裡留出頂部與底部膠囊的空間，內容不會被遮住
        web.scrollView.contentInset = UIEdgeInsets(top: 64, left: 0, bottom: 72, right: 0)
        ContentBlocker.apply(to: web, enabled: Prefs.blockTrackers)

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
            web.observe(\.hasOnlySecureContent) { [weak self] wv, _ in self?.isSecure = wv.hasOnlySecureContent },
            web.observe(\.isLoading) { [weak self] wv, _ in
                self?.isLoading = wv.isLoading
                if !wv.isLoading {
                    wv.scrollView.refreshControl?.endRefreshing()
                }
            }
        ]
        observers.append(web.scrollView.observe(\.contentOffset) { [weak self] sv, _ in
            self?.scrolled(sv)
        })
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        if web.url == nil {
            sender.endRefreshing()
        } else {
            web.reload()
        }
    }

    // 往下捲動時收起工具列，往上捲動或回到頂端時顯示
    private func scrolled(_ sv: UIScrollView) {
        let y = sv.contentOffset.y
        let delta = y - lastOffsetY
        lastOffsetY = y
        let topY = -sv.adjustedContentInset.top
        if y <= topY + 30 {
            if barsCollapsed { barsCollapsed = false }
            return
        }
        guard sv.isTracking || sv.isDecelerating else { return }
        if delta > 6, !barsCollapsed {
            barsCollapsed = true
        } else if delta < -6, barsCollapsed {
            barsCollapsed = false
        }
    }

    // 延遲載入：還原上次的分頁時，只有被選到的才真的載入
    func loadIfNeeded() {
        if let target = pendingURL, web.url == nil {
            pendingURL = nil
            web.load(URLRequest(url: target))
        }
    }

    // 擷取目前畫面，作為分頁總覽的預覽圖
    func captureSnapshot() {
        guard url != nil, !isLoading || progress > 0.5 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 360)
        web.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    // 有網域就直接前往，否則用選定的搜尋引擎搜尋
    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingURL = nil
        var target: URL?
        if text.contains("://") || text.hasPrefix("about:") {
            target = URL(string: text)
        } else if text.hasPrefix("localhost") {
            target = URL(string: "http://" + text)
        } else if text.contains("."), !text.contains(" ") {
            target = URL(string: "https://" + text)
        } else {
            target = Prefs.engine.searchURL(text)
        }
        if let target {
            web.load(URLRequest(url: target))
        }
    }

    func setDesktopMode(_ on: Bool) {
        desktopMode = on
        web.reload()
    }

    // MARK: 文字大小

    func zoom(by delta: CGFloat) {
        setZoom(pageZoom + delta)
    }

    func resetZoom() {
        setZoom(1)
    }

    private func setZoom(_ value: CGFloat) {
        pageZoom = min(max(value, 0.5), 3)
        web.pageZoom = pageZoom
    }

    // MARK: 尋找、列印、分享、PDF

    func showFind() {
        web.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func printPage() {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = web.viewPrintFormatter()
        _ = controller.present(animated: true, completionHandler: nil)
    }

    func sharePage() {
        if let url {
            presentShare([url])
        }
    }

    func savePDF() {
        web.createPDF { [weak self] result in
            guard let self, case .success(let data) = result else { return }
            let base = self.title.isEmpty ? "網頁" : self.title.replacingOccurrences(of: "/", with: "-")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".pdf")
            do {
                try data.write(to: file)
                presentShare([file])
            } catch {
                presentAlert(title: nil, message: "無法建立 PDF")
            }
        }
    }

    // 分頁被關閉時，停止載入，避免背景繼續跑
    func teardown() {
        web.stopLoading()
    }

    // MARK: 閱讀器

    func toggleReader() {
        if isReader {
            exitReader()
        } else {
            enterReader()
        }
    }

    private func exitReader() {
        isReader = false
        if let original = readerOriginalURL {
            web.load(URLRequest(url: original))
        } else {
            web.reload()
        }
    }

    private func enterReader() {
        guard let current = web.url else { return }
        web.evaluateJavaScript(BrowserTab.readerScript) { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = object["html"] as? String,
                  !content.isEmpty else {
                presentAlert(title: nil, message: "此頁面無法使用閱讀器")
                return
            }
            let pageTitle = (object["title"] as? String) ?? self.title
            self.readerOriginalURL = current
            self.readerLoading = true
            self.isReader = true
            self.web.loadHTMLString(BrowserTab.readerHTML(title: pageTitle, content: content), baseURL: current)
        }
    }

    private static func readerHTML(title: String, content: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: 20px/1.65 -apple-system, "PingFang TC", sans-serif; max-width: 680px; margin: 0 auto; padding: 24px 20px 120px; word-wrap: break-word; }
        h1 { font-size: 1.6em; line-height: 1.25; }
        img, video, iframe { max-width: 100%; height: auto; border-radius: 8px; }
        a { color: #0a84ff; }
        pre { overflow: auto; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #8888; }
        </style></head><body><h1>\(htmlEscape(title))</h1>\(content)</body></html>
        """
    }

    private static let readerScript = #"""
    (function () {
      try {
        var junk = 'script,style,noscript,nav,aside,footer,form,iframe,button,svg,canvas,dialog,header,[role=navigation],[role=banner],[role=complementary],[aria-hidden=true],.ad,.ads,.advert,.share,.social,.comments,#comments,.related,.newsletter,.cookie,.popup,.modal';
        function textLen(el) { return (el.innerText || '').trim().length; }
        function score(el) {
          var s = 0;
          var ps = el.querySelectorAll(':scope > p, :scope > div > p');
          for (var i = 0; i < ps.length; i++) {
            var l = (ps[i].innerText || '').trim().length;
            if (l > 40) { s += l; }
          }
          return s;
        }
        var best = null, bestScore = 0;
        var arts = document.querySelectorAll('article');
        for (var a = 0; a < arts.length; a++) {
          var sa = textLen(arts[a]);
          if (sa > bestScore) { best = arts[a]; bestScore = sa; }
        }
        if (bestScore < 500) {
          best = null; bestScore = 0;
          var els = document.querySelectorAll('main, [role=main], section, div');
          for (var i = 0; i < els.length; i++) {
            var s = score(els[i]);
            if (s > bestScore) { best = els[i]; bestScore = s; }
          }
        }
        if (!best || bestScore < 300) { return JSON.stringify({ ok: false }); }
        var clone = best.cloneNode(true);
        clone.querySelectorAll(junk).forEach(function (n) { n.remove(); });
        clone.querySelectorAll('[style]').forEach(function (n) { n.removeAttribute('style'); });
        clone.querySelectorAll('img').forEach(function (img) {
          var ds = img.getAttribute('data-src') || img.getAttribute('data-original');
          if (ds && !img.getAttribute('src')) { img.setAttribute('src', ds); }
          img.removeAttribute('loading');
        });
        var meta = document.querySelector('meta[property="og:title"]');
        var title = (meta && meta.content) ? meta.content : document.title;
        return JSON.stringify({ ok: true, title: title, html: clone.innerHTML });
      } catch (e) {
        return JSON.stringify({ ok: false });
      }
    })()
    """#

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if readerLoading {
            readerLoading = false
        } else if isReader {
            isReader = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigated?()
        guard !isPrivate, !isReader, webView.title != BrowserTab.errorTitle,
              let pageURL = webView.url,
              pageURL.scheme == "http" || pageURL.scheme == "https" else { return }
        let pageTitle = webView.title ?? ""
        store.addHistory(title: pageTitle.isEmpty ? pageURL.absoluteString : pageTitle, url: pageURL.absoluteString)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? webView.url?.absoluteString ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(BrowserTab.errorTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 17px -apple-system, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 80vh; padding: 24px; text-align: center; }
        p { color: #8e8e93; word-break: break-all; }
        a { display: inline-block; margin-top: 16px; padding: 12px 24px; border-radius: 12px; background: #0a84ff; color: #fff; text-decoration: none; }
        </style></head><body>
        <h2>\(BrowserTab.errorTitle)</h2>
        <p>\(htmlEscape(ns.localizedDescription))</p>
        <a href="\(htmlEscape(failing))">重新載入</a>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failing))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // tel:、mailto:、App Store 等連結交給系統處理
        if let target = navigationAction.request.url,
           let scheme = target.scheme?.lowercased(),
           !["http", "https", "about", "file", "data", "blob", "javascript"].contains(scheme) {
            UIApplication.shared.open(target)
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        preferences.allowsContentJavaScript = Prefs.javaScriptEnabled
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    // 需要帳號密碼的網站（HTTP 基本驗證）
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              let top = topViewController() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = UIAlertController(title: "需要登入", message: challenge.protectionSpace.host, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "使用者名稱"
            field.autocapitalizationType = .none
        }
        alert.addTextField { field in
            field.placeholder = "密碼"
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            completionHandler(.cancelAuthenticationChallenge, nil)
        })
        alert.addAction(UIAlertAction(title: "登入", style: .default) { [weak alert] _ in
            let user = alert?.textFields?.first?.text ?? ""
            let pass = alert?.textFields?.last?.text ?? ""
            completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
        })
        top.present(alert, animated: true)
    }

    // MARK: WKUIDelegate

    // target="_blank" 的連結改為開新分頁
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = BrowserTab(store: store, isPrivate: isPrivate, configuration: configuration)
        onOpenTab?(tab)
        return tab.web
    }

    // 網頁呼叫 window.close() 時關閉這個分頁
    func webViewDidClose(_ webView: WKWebView) {
        onClose?(self)
    }

    private func dialog(host: String?,
                        message: String,
                        defaultText: String?,
                        showCancel: Bool,
                        showField: Bool,
                        completion: @escaping (Bool, String?) -> Void) {
        guard let top = topViewController() else {
            completion(false, nil)
            return
        }
        let alert = UIAlertController(title: host ?? "網頁訊息", message: message, preferredStyle: .alert)
        if showField {
            alert.addTextField { field in
                field.text = defaultText
            }
        }
        if showCancel {
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completion(false, nil)
            })
        }
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in
            completion(true, alert?.textFields?.first?.text)
        })
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        dialog(host: frame.request.url?.host, message: message, defaultText: nil, showCancel: false, showField: false) { _, _ in
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        dialog(host: frame.request.url?.host, message: message, defaultText: nil, showCancel: true, showField: false) { ok, _ in
            completionHandler(ok)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        dialog(host: frame.request.url?.host, message: prompt, defaultText: defaultText, showCancel: true, showField: true) { ok, text in
            completionHandler(ok ? (text ?? "") : nil)
        }
    }

    // 相機與麥克風：交給系統詢問
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

// MARK: - 分頁管理

// 管理所有分頁與目前選取的分頁
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var recentlyClosed: [String] = []
    let store = BrowserStore()

    init() {
        restoreSession()
        ContentBlocker.compile { [weak self] in
            self?.refreshContentBlocker()
        }
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
        let wasSelected = (selectedID == tab.id)
        record(tab)
        tab.teardown()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tabs.remove(at: index)
            if tabs.isEmpty {
                addTab()
            } else if wasSelected || !tabs.contains(where: { $0.id == selectedID }) {
                // 優先選擇相鄰、同類型（一般／私密）的分頁
                let after = tabs[index...].first { $0.isPrivate == tab.isPrivate }
                let before = tabs[..<index].last { $0.isPrivate == tab.isPrivate }
                selectedID = (after ?? before ?? tabs.last)?.id
            }
        }
        afterClosing()
    }

    func closeAll(isPrivate: Bool) {
        for tab in tabs where tab.isPrivate == isPrivate {
            record(tab)
            tab.teardown()
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tabs.removeAll { $0.isPrivate == isPrivate }
            if tabs.isEmpty {
                addTab()
            } else if !tabs.contains(where: { $0.id == selectedID }) {
                selectedID = tabs.last?.id
            }
        }
        afterClosing()
    }

    func closeOthers(except keep: BrowserTab) {
        for tab in tabs where tab.id != keep.id && tab.isPrivate == keep.isPrivate {
            record(tab)
            tab.teardown()
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tabs.removeAll { $0.id != keep.id && $0.isPrivate == keep.isPrivate }
            selectedID = keep.id
        }
        afterClosing()
    }

    func duplicate(_ tab: BrowserTab) {
        addTab(url: tab.url?.absoluteString, isPrivate: tab.isPrivate)
    }

    func reopenClosedTab() {
        guard !recentlyClosed.isEmpty else { return }
        let target = recentlyClosed.removeFirst()
        addTab(url: target)
    }

    // 在同類型的分頁之間左右切換；已經在最後一個時，往左滑會新增分頁
    func selectAdjacent(_ delta: Int) {
        guard let cur = current else { return }
        let group = tabs.filter { $0.isPrivate == cur.isPrivate }
        guard let index = group.firstIndex(where: { $0.id == cur.id }) else { return }
        let target = index + delta
        if group.indices.contains(target) {
            selectedID = group[target].id
        } else if delta > 0 {
            addTab(isPrivate: cur.isPrivate)
        }
    }

    func clearBrowsingData() {
        store.clearHistory()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    func refreshContentBlocker() {
        let enabled = Prefs.blockTrackers
        for tab in tabs {
            ContentBlocker.apply(to: tab.web, enabled: enabled)
        }
    }

    private func record(_ tab: BrowserTab) {
        guard !tab.isPrivate, let address = tab.url?.absoluteString ?? tab.pendingURL?.absoluteString else { return }
        recentlyClosed.insert(address, at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(20))
    }

    private func afterClosing() {
        // 私密分頁全部關閉後，丟棄私密瀏覽的 Cookie 與網站資料
        if !tabs.contains(where: { $0.isPrivate }) {
            BrowserTab.privateDataStore = WKWebsiteDataStore.nonPersistent()
        }
        saveSession()
    }

    // MARK: 還原上次開啟的分頁

    private func restoreSession() {
        let saved = UserDefaults.standard.stringArray(forKey: "session.urls") ?? []
        let savedIndex = UserDefaults.standard.integer(forKey: "session.selected")
        guard !saved.isEmpty else {
            addTab()
            return
        }
        for text in saved {
            let tab = addTab()
            if let target = URL(string: text) {
                tab.pendingURL = target
                tab.url = target
                tab.title = target.host ?? text
            }
        }
        if tabs.indices.contains(savedIndex) {
            selectedID = tabs[savedIndex].id
        }
        saveSession()
    }

    private func saveSession() {
        let normal = tabs.filter { !$0.isPrivate }
        let urls = normal.compactMap { $0.url?.absoluteString }
        UserDefaults.standard.set(urls, forKey: "session.urls")
        if let cur = current, !cur.isPrivate,
           let address = cur.url?.absoluteString,
           let index = urls.firstIndex(of: address) {
            UserDefaults.standard.set(index, forKey: "session.selected")
        }
    }

    private func attach(_ tab: BrowserTab) {
        tab.onOpenTab = { [weak self] newTab in self?.attach(newTab) }
        tab.onClose = { [weak self] closing in self?.closeTab(closing) }
        tab.onNavigated = { [weak self] in self?.saveSession() }
        tabs.append(tab)
        selectedID = tab.id
        saveSession()
    }
}

// MARK: - 主畫面

struct ContentView: View {
    @StateObject var model = BrowserModel()

    var body: some View {
        if let tab = model.current {
            BrowserPage(model: model, tab: tab, store: model.store)
        }
    }
}

// 網址欄輸入時的搜尋建議（本機書籤與歷史＋搜尋引擎建議）
final class SuggestionModel: ObservableObject {
    @Published var remote: [String] = []
    @Published var local: [SavedLink] = []
    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        remote = []
        local = []
    }

    func update(query: String, store: BrowserStore) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            remote = []
            local = []
            return
        }
        let lower = q.lowercased()
        var seen = Set<String>()
        var matches: [SavedLink] = []
        for link in store.bookmarks + store.history {
            let hit = link.title.lowercased().contains(lower) || link.url.lowercased().contains(lower)
            if hit, seen.insert(link.url).inserted {
                matches.append(link)
            }
            if matches.count >= 5 { break }
        }
        local = matches

        guard Prefs.showSuggestions, let url = Prefs.engine.suggestURL(q) else {
            remote = []
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            guard let result = try? await URLSession.shared.data(from: url) else { return }
            let list = SearchEngine.parseSuggestions(result.0)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.remote = Array(list.prefix(6))
            }
        }
    }
}

struct SuggestionList: View {
    let query: String
    let local: [SavedLink]
    let remote: [String]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                row(icon: "magnifyingglass", title: query, subtitle: nil) { onPick(query) }
                ForEach(remote, id: \.self) { text in
                    row(icon: "magnifyingglass", title: text, subtitle: nil) { onPick(text) }
                }
                ForEach(local) { link in
                    row(icon: "clock", title: link.title, subtitle: link.url) { onPick(link.url) }
                }
            }
            .padding(.top, 72)
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private func row(icon: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BrowserPage: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @ObservedObject var downloads = DownloadManager.shared
    @StateObject var suggestions = SuggestionModel()

    @State var showTabs = false
    @State var showLibrary = false
    @State var librarySection: LibrarySection = .bookmarks
    @State var showDownloads = false
    @State var showSettings = false
    @State var edited = false
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

    private var barsHidden: Bool {
        tab.barsCollapsed && !addressFocused
    }

    private var showSuggestionList: Bool {
        addressFocused && edited && !tab.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        base
            .fullScreenCover(isPresented: $showTabs) {
                TabOverview(isPresented: $showTabs, model: model, store: store)
            }
            .sheet(isPresented: $showLibrary) {
                LibrarySheet(isPresented: $showLibrary, store: store, section: librarySection) { tab.go($0) }
            }
            .sheet(isPresented: $showDownloads) {
                DownloadsSheet(isPresented: $showDownloads)
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(isPresented: $showSettings, model: model)
            }
    }

    private var base: some View {
        mainStack
            .preferredColorScheme(tab.isPrivate ? .dark : nil)
            .onAppear {
                tab.loadIfNeeded()
            }
            .onChange(of: tab.id) { _ in
                addressFocused = false
                tab.loadIfNeeded()
            }
            .onChange(of: tab.address) { value in
                guard addressFocused else { return }
                edited = true
                suggestions.update(query: value, store: store)
            }
            .onChange(of: addressFocused) { focused in
                if focused {
                    edited = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        _ = UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                } else {
                    suggestions.clear()
                }
            }
    }

    private var mainStack: some View {
        ZStack {
            ZStack {
                WebViewRepresentable(webView: tab.web)
                if tab.url == nil {
                    startPage
                }
            }
            .ignoresSafeArea()

            if showSuggestionList {
                SuggestionList(query: tab.address, local: suggestions.local, remote: suggestions.remote) { picked in
                    tab.go(picked)
                    addressFocused = false
                }
            }

            VStack(spacing: 0) {
                if barsHidden {
                    compactBar
                } else {
                    topBar
                }
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .opacity(tab.isLoading ? 1 : 0)
                    .allowsHitTesting(false)
                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: barsHidden)

            VStack(spacing: 8) {
                Spacer()
                downloadBanner
                bottomBar
                    .offset(y: barsHidden ? 140 : 0)
                    .opacity(barsHidden ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.2), value: barsHidden)
            .animation(.default, value: downloads.banner)
        }
    }

    // 捲動時收起工具列後，頂端只留一個小膠囊，點一下就恢復
    private var compactBar: some View {
        Button {
            withAnimation { tab.barsCollapsed = false }
        } label: {
            HStack(spacing: 4) {
                securityIcon
                Text(displayHost)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .liquidGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var securityIcon: some View {
        if let url = tab.url, url.scheme == "http" {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        } else if tab.isSecure {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
        }
    }

    // 頂部浮動膠囊：頁面選單、網址與重新整理
    private var topBar: some View {
        HStack(spacing: 6) {
            pageMenu
            addressField
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

    // 類似 Safari 的「aA」選單：閱讀器、文字大小、桌面版網站、尋找頁面
    private var pageMenu: some View {
        Menu {
            Button {
                tab.toggleReader()
            } label: {
                Label(tab.isReader ? "隱藏閱讀器" : "顯示閱讀器", systemImage: "doc.plaintext")
            }
            .disabled(tab.url == nil)
            Divider()
            Button {
                tab.zoom(by: 0.1)
            } label: {
                Label("放大文字", systemImage: "textformat.size.larger")
            }
            Button {
                tab.zoom(by: -0.1)
            } label: {
                Label("縮小文字", systemImage: "textformat.size.smaller")
            }
            Button {
                tab.resetZoom()
            } label: {
                Label("重設文字大小（\(Int((tab.pageZoom * 100).rounded()))%）", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button {
                tab.setDesktopMode(!tab.desktopMode)
            } label: {
                Label(tab.desktopMode ? "請求行動版網站" : "請求桌面版網站", systemImage: "desktopcomputer")
            }
            Button {
                tab.showFind()
            } label: {
                Label("尋找頁面", systemImage: "magnifyingglass")
            }
            .disabled(tab.url == nil)
            Button {
                withAnimation { tab.barsCollapsed = true }
            } label: {
                Label("隱藏工具列", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        } label: {
            symbolImage("textformat.size")
        }
        .buttonStyle(.plain)
    }

    private var addressField: some View {
        ZStack {
            // 輸入用的欄位：只在編輯時接收觸控，由下方的顯示層點一下來啟動
            TextField("搜尋或輸入網址", text: $tab.address)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .opacity(addressFocused ? 1 : 0)
                .allowsHitTesting(addressFocused)
                .onSubmit {
                    tab.go(tab.address)
                    addressFocused = false
                }
            if !addressFocused {
                HStack(spacing: 4) {
                    if tab.isReader {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 13))
                    }
                    securityIcon
                    Text(displayHost)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    addressFocused = true
                }
                .gesture(swipeGesture)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 在網址列上左右滑動切換分頁；在最後一個分頁往左滑會新增分頁
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) else { return }
                withAnimation {
                    model.selectAdjacent(dx < 0 ? 1 : -1)
                }
            }
    }

    // 底部浮動膠囊：上一頁、下一頁、分享選單、書籤與分頁
    private var bottomBar: some View {
        HStack {
            navButton("chevron.backward") { tab.web.goBack() }
                .disabled(!tab.canGoBack)
                .contextMenu { historyMenu(back: true) }
            Spacer()
            navButton("chevron.forward") { tab.web.goForward() }
                .disabled(!tab.canGoForward)
                .contextMenu { historyMenu(back: false) }
            Spacer()
            shareMenu
            Spacer()
            navButton("book") {
                librarySection = .bookmarks
                showLibrary = true
            }
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

    // 長按上一頁／下一頁，列出這個分頁的瀏覽紀錄
    @ViewBuilder
    private func historyMenu(back: Bool) -> some View {
        ForEach(Array(historyItems(back: back).enumerated()), id: \.offset) { pair in
            Button(itemTitle(pair.element)) {
                _ = tab.web.go(to: pair.element)
            }
        }
    }

    private func historyItems(back: Bool) -> [WKBackForwardListItem] {
        let list = tab.web.backForwardList
        if back {
            return Array(list.backList.reversed().prefix(10))
        }
        return Array(list.forwardList.prefix(10))
    }

    private func itemTitle(_ item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty {
            return title
        }
        return item.url.host ?? item.url.absoluteString
    }

    // 類似 Safari 分享選單的功能集合
    private var shareMenu: some View {
        Menu {
            Button {
                tab.sharePage()
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
            .disabled(tab.url == nil)
            Divider()
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
                Button {
                    store.addFavorite(title: tab.title, url: currentURL)
                } label: {
                    Label("加入喜好項目", systemImage: "star")
                }
                Button {
                    store.addReading(title: tab.title, url: currentURL)
                } label: {
                    Label("加入閱讀清單", systemImage: "eyeglasses")
                }
                Divider()
                Button {
                    tab.printPage()
                } label: {
                    Label("列印", systemImage: "printer")
                }
                Button {
                    tab.savePDF()
                } label: {
                    Label("儲存為 PDF", systemImage: "doc.richtext")
                }
                Divider()
            }
            Button {
                showDownloads = true
            } label: {
                Label("下載項目", systemImage: "arrow.down.circle")
            }
            Button {
                showSettings = true
            } label: {
                Label("設定", systemImage: "gearshape")
            }
        } label: {
            symbolImage("square.and.arrow.up")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var downloadBanner: some View {
        if let text = downloads.banner {
            Button {
                showDownloads = true
            } label: {
                Label(text, systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // 空白分頁顯示的起始頁（喜好項目與閱讀清單）
    private var startPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tab.isPrivate {
                Text("私密瀏覽").font(.title2.bold())
                Text("私密分頁不會記錄歷史紀錄；關閉所有私密分頁後，Cookie 與網站資料也不會保留。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("喜好項目").font(.title3.bold())
                if store.favorites.isEmpty {
                    Text("加入喜好項目後會顯示在這裡").font(.footnote).foregroundStyle(.secondary)
                }
                FavoritesGrid(links: store.favorites, iconSize: 60) { tab.go($0) }
                if !store.readingList.isEmpty {
                    Text("閱讀清單").font(.title3.bold()).padding(.top, 8)
                    ForEach(store.readingList.prefix(3)) { link in
                        Button {
                            tab.go(link.url)
                        } label: {
                            Text(link.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 130)
        .padding(.bottom, 110)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
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

// MARK: - 分頁總覽

// 分頁總覽：2 欄卡片，新增與關閉都有動畫
struct TabOverview: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: BrowserModel
    @ObservedObject var store: BrowserStore
    @State var privateMode = false
    @State var query = ""
    @State var knownCount = 0

    init(isPresented: Binding<Bool>, model: BrowserModel, store: BrowserStore) {
        _isPresented = isPresented
        _model = ObservedObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: store)
    }

    private var modeTabs: [BrowserTab] {
        model.tabs.filter { $0.isPrivate == privateMode }
    }

    private var visibleTabs: [BrowserTab] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return modeTabs }
        return modeTabs.filter { tab in
            tab.title.lowercased().contains(q) || (tab.url?.absoluteString.lowercased().contains(q) ?? false)
        }
    }

    private var normalCount: Int {
        model.tabs.filter { !$0.isPrivate }.count
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    if modeTabs.count > 3 {
                        searchField
                    }
                    if visibleTabs.isEmpty {
                        Text(privateMode ? "沒有私密分頁" : "沒有標籤頁")
                            .foregroundStyle(.secondary)
                            .padding(.top, 120)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                              spacing: 22) {
                        ForEach(visibleTabs) { tab in
                            card(for: tab)
                                .id(tab.id)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 120)
                }
                bottomBar
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .onAppear {
                knownCount = model.tabs.count
            }
            // 新增分頁後，等卡片真的出現在畫面上再捲動過去
            .onChange(of: model.tabs.count) { newCount in
                let added = newCount > knownCount
                knownCount = newCount
                guard added, let id = visibleTabs.last?.id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋分頁", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func card(for tab: BrowserTab) -> some View {
        TabCard(
            tab: tab,
            favorites: store.favorites,
            onSelect: {
                model.selectedID = tab.id
                isPresented = false
            },
            onClose: {
                model.closeTab(tab)
            },
            onDuplicate: {
                model.duplicate(tab)
            },
            onCloseOthers: {
                model.closeOthers(except: tab)
            },
            onBookmark: {
                if let address = tab.url?.absoluteString {
                    store.toggleBookmark(title: tab.title, url: address)
                }
            }
        )
    }

    private var bottomBar: some View {
        liquidGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        _ = model.addTab(isPrivate: privateMode)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        withAnimation { model.reopenClosedTab() }
                    } label: {
                        Label("重新開啟最近關閉的分頁", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.recentlyClosed.isEmpty)
                    Button {
                        withAnimation { _ = model.addTab(isPrivate: !privateMode) }
                    } label: {
                        Label(privateMode ? "新增分頁" : "新增私密分頁", systemImage: privateMode ? "plus.square" : "eye.slash")
                    }
                }

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
                .contextMenu {
                    Button(role: .destructive) {
                        model.closeAll(isPrivate: privateMode)
                    } label: {
                        Label(privateMode ? "關閉所有私密分頁" : "關閉所有分頁", systemImage: "xmark.square")
                    }
                }
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

// 單一分頁卡片：預覽圖、右上角關閉按鈕與標題；長按有更多選項
struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let favorites: [SavedLink]
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onCloseOthers: () -> Void
    let onBookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                    .contextMenu {
                        Button {
                            onDuplicate()
                        } label: {
                            Label("複製分頁", systemImage: "plus.square.on.square")
                        }
                        if tab.url != nil {
                            Button {
                                onBookmark()
                            } label: {
                                Label("加入或移除書籤", systemImage: "bookmark")
                            }
                            Button {
                                tab.sharePage()
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button {
                            onCloseOthers()
                        } label: {
                            Label("關閉其他分頁", systemImage: "xmark.square")
                        }
                        Button(role: .destructive) {
                            onClose()
                        } label: {
                            Label("關閉分頁", systemImage: "xmark")
                        }
                    }
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

// MARK: - 書籤、閱讀清單、歷史紀錄

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks = "書籤"
    case reading = "閱讀清單"
    case history = "歷史紀錄"

    var id: String { rawValue }
}

private struct DayGroup: Identifiable {
    let day: Date
    let items: [SavedLink]
    var id: Date { day }
}

struct LibrarySheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: BrowserStore
    @State private var section: LibrarySection
    @State private var query = ""
    @State private var confirmClear = false
    let onOpen: (String) -> Void

    init(isPresented: Binding<Bool>, store: BrowserStore, section: LibrarySection, onOpen: @escaping (String) -> Void) {
        _isPresented = isPresented
        _store = ObservedObject(wrappedValue: store)
        _section = State(initialValue: section)
        self.onOpen = onOpen
    }

    private var kind: BrowserStore.Kind {
        switch section {
        case .bookmarks: return .bookmarks
        case .reading: return .reading
        case .history: return .history
        }
    }

    private var items: [SavedLink] {
        let source: [SavedLink]
        switch section {
        case .bookmarks: source = store.bookmarks
        case .reading: source = store.readingList
        case .history: source = store.history
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return source }
        return source.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    private var dayGroups: [DayGroup] {
        let grouped = Dictionary(grouping: items, by: { Calendar.current.startOfDay(for: $0.date) })
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(LibrarySection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if items.isEmpty {
                        Text("目前沒有項目").foregroundStyle(.secondary)
                    }
                    if section == .history {
                        ForEach(dayGroups) { group in
                            Section(header: Text(group.day, style: .date)) {
                                ForEach(group.items) { link in
                                    row(link)
                                }
                            }
                        }
                    } else {
                        ForEach(items) { link in
                            row(link)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜尋")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if section == .history && !store.history.isEmpty {
                        Button("清除") { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("清除歷史紀錄？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) { store.clearHistory() }
            }
        }
    }

    private func row(_ link: SavedLink) -> some View {
        Button {
            onOpen(link.url)
            isPresented = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).lineLimit(1)
                    Text(link.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if link.favorite && section == .bookmarks {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(link.id, kind: kind)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if section == .bookmarks {
                Button {
                    store.toggleFavorite(link.id)
                } label: {
                    Label(link.favorite ? "取消喜好" : "加入喜好", systemImage: link.favorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = link.url
            } label: {
                Label("拷貝網址", systemImage: "doc.on.doc")
            }
            Button {
                presentShare([link.url])
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - 下載項目

struct DownloadsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var downloads = DownloadManager.shared

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    var body: some View {
        NavigationStack {
            List {
                if downloads.items.isEmpty {
                    Text("目前沒有下載項目").foregroundStyle(.secondary)
                }
                ForEach(downloads.items) { item in
                    Button {
                        if let file = item.fileURL, item.state == .finished {
                            presentShare([file])
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).lineLimit(1)
                            switch item.state {
                            case .running:
                                ProgressView(value: item.progress)
                            case .finished:
                                Text("已完成，點一下可分享或儲存到「檔案」")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            case .failed:
                                Text("下載失敗")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            downloads.remove(item.id)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("下載項目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if !downloads.items.isEmpty {
                        Button("全部清除") { downloads.removeAll() }
                    }
                }
            }
        }
    }
}

// MARK: - 設定

struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: BrowserModel
    @AppStorage("searchEngine") private var engine = SearchEngine.google.rawValue
    @AppStorage("showSuggestions") private var showSuggestions = true
    @AppStorage("blockPopups") private var blockPopups = true
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("blockTrackers") private var blockTrackers = true
    @State private var confirmClear = false

    init(isPresented: Binding<Bool>, model: BrowserModel) {
        _isPresented = isPresented
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("搜尋")) {
                    Picker("搜尋引擎", selection: $engine) {
                        ForEach(SearchEngine.allCases) { item in
                            Text(item.name).tag(item.rawValue)
                        }
                    }
                    Toggle("搜尋建議", isOn: $showSuggestions)
                }
                Section(header: Text("隱私權與安全性"),
                        footer: Text("跨網站追蹤防護（智慧型追蹤防護）由 WebKit 預設啟用。彈出式視窗設定對之後新開的分頁生效。")) {
                    Toggle("封鎖彈出式視窗", isOn: $blockPopups)
                    Toggle("啟用 JavaScript", isOn: $javaScriptEnabled)
                    Toggle("封鎖廣告與追蹤器", isOn: $blockTrackers)
                        .onChange(of: blockTrackers) { _ in
                            model.refreshContentBlocker()
                        }
                }
                Section {
                    Button("清除歷史紀錄與網站資料", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .confirmationDialog("清除歷史紀錄、Cookie 與快取？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) { model.clearBrowsingData() }
            }
        }
    }
}

// 用容器包住 WKWebView：切換分頁時，updateUIView 會把新的 WKWebView 換進來
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        mount(webView, in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if container.subviews.first !== webView {
            mount(webView, in: container)
        }
    }

    private func mount(_ web: WKWebView, in container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}
