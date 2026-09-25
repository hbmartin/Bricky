import Foundation

/// Decides what to do with a URL the system hands Bricky ("Open in Bricky"
/// from Files, Mail, or AirDrop). Info.plist has always declared the LDraw
/// document types, but nothing handled the URL, so opening a file launched
/// the app and did nothing.
enum DocumentOpenRouter {
    enum Route: Equatable {
        case importFile(URL)
        case rejected(String)
    }

    static let acceptedExtensions: Set<String> = ["mpd", "ldr"]

    static func route(_ url: URL) -> Route {
        guard url.isFileURL else {
            return .rejected("Bricky opens LDraw instruction files, not links.")
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .rejected("Open a folder from the Library's Import Folder button so its root model can be chosen.")
        }
        guard acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            return .rejected("Bricky opens authored .mpd files and stepped .ldr files; “\(url.lastPathComponent)” is neither.")
        }
        return .importFile(url)
    }

    /// A copy iOS placed in `Documents/Inbox` for an app that could not open
    /// the original in place. Bricky imports it into its own store, so the
    /// copy is deleted afterwards rather than accumulating.
    static func isInboxCopy(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard let inbox = components.lastIndex(of: "Inbox"), inbox > 0 else { return false }
        return components[inbox - 1] == "Documents"
    }
}
