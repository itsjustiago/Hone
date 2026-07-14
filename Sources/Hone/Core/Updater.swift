import Foundation

struct UpdateInfo {
    let version: String
    let pageURL: URL
    let zipURL: URL?
}

/// Lightweight update check against the GitHub Releases API (no auto-download).
/// Ported from Clippy/Sleepy so Hone gets the same in-app update flow.
enum Updater {
    static let repo = "itsjustiago/Hone"

    static var currentVersion: String {
        if let debug = ProcessInfo.processInfo.environment["HONE_DEBUG_VERSION"] { return debug }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    /// Returns update info only when a newer release exists.
    static func check(completion: @escaping (UpdateInfo?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var result: UpdateInfo?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               isNewer(tag, than: currentVersion) {
                let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/\(repo)/releases/latest")!
                var zip: URL?
                if let assets = json["assets"] as? [[String: Any]] {
                    for a in assets where (a["name"] as? String) == "Hone.zip" {
                        zip = (a["browser_download_url"] as? String).flatMap(URL.init(string:))
                    }
                }
                result = UpdateInfo(version: tag, pageURL: page, zipURL: zip)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
