import Foundation

/// Shared resolution for "open <site> in <browser>" and local dev URLs.
/// The Rust core owns the canonical site/browser tables and the port rules.
enum OpenTargetResolver {
    static func canonicalBrowser(_ raw: String) -> String? {
        coreCanonicalBrowser(raw: raw)
    }

    static func siteURL(for raw: String) -> String? {
        coreSiteUrl(raw: raw)
    }

    /// "open chatgpt in brave", "open vercel on google chrome",
    /// "open claude code using arc".
    static func parseOpenInBrowser(_ lower: String) -> (url: String, browser: String)? {
        coreParseOpenInBrowser(lower: lower).map { ($0.url, $0.browser) }
    }

    /// React/Vite defaults to 5173; a bare localhost defaults to 3000.
    /// Local development opens in Brave unless another browser is named.
    static func parseLocalDev(_ lower: String) -> (url: String, browser: String)? {
        coreParseLocalDev(lower: lower).map { ($0.url, $0.browser) }
    }
}
