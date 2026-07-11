import QuickLookUI

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL

        let entries: [IsoEntry]
        do {
            entries = try listEntries(from: url)
        } catch {
            let html = errorPageHTML(message: "Could not read ISO: \(error.localizedDescription)")
            let data = html.data(using: .utf8) ?? Data()
            let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
            completionHandler(reply, nil)
            return
        }

        let html = generateHTML(entries: entries, filename: url.lastPathComponent)
        guard let data = html.data(using: .utf8) else {
            completionHandler(nil, NSError(domain: "IsoPreviewError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
            return
        }

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in data }
        completionHandler(reply, nil)
    }

    // MARK: - Entry Listing via libarchive C bridge

    private struct IsoEntry {
        let path: String
        let size: Int64
        let isDirectory: Bool
    }

    private enum IsoError: Error {
        case cannotOpen
        case parseFailed(description: String)
    }

    private func listEntries(from url: URL) throws -> [IsoEntry] {
        guard let jsonStr = archive_list_entries(url.path) else {
            throw IsoError.cannotOpen
        }
        defer { archive_free_json(jsonStr) }

        let str = String(cString: jsonStr)
        guard let data = str.data(using: .utf8) else {
            throw IsoError.parseFailed(description: "invalid encoding")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        guard let items = json else {
            throw IsoError.parseFailed(description: "invalid JSON")
        }

        return items.compactMap { item -> IsoEntry? in
            guard let name = item["name"] as? String,
                  let size = item["size"] as? Int64,
                  let isDir = item["isDirectory"] as? Bool
            else { return nil }
            return IsoEntry(path: name, size: size, isDirectory: isDir)
        }
    }

    // MARK: - HTML Generation

    private func generateHTML(entries: [IsoEntry], filename: String) -> String {
        let totalFiles = entries.filter { !$0.isDirectory }.count
        let totalDirs = entries.filter { $0.isDirectory }.count

        let rows = entries.isEmpty
            ? "<div class=\"empty\">ISO is empty</div>"
            : entries.map { entry -> String in
                let sizeStr = entry.isDirectory ? "" : formatSize(entry.size)
                let cls = entry.isDirectory ? "entry dir" : "entry"
                return """
                <div class="\(cls)">
                    <span class="name">\(escapeHTML(entry.path))</span>
                    \(sizeStr.isEmpty ? "" : "<span class=\"size\">\(sizeStr)</span>")
                </div>
                """
            }.joined()

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{
                font-family:-apple-system,'SF Mono',Menlo,monospace;
                font-size:12px;background:#1e1e1e;color:#d4d4d4;
                padding:16px;overflow-y:auto;
            }
            .header{
                border-bottom:1px solid #333;
                padding-bottom:10px;margin-bottom:12px;
            }
            .filename{
                color:#569cd6;font-size:14px;font-weight:600;
            }
            .summary{
                color:#808080;font-size:11px;margin-top:4px;
            }
            .entry{
                display:flex;justify-content:space-between;
                padding:6px 10px;border-bottom:1px solid #2a2a2a;
            }
            .entry:last-child{border-bottom:none}
            .entry.dir{background:rgba(86,156,214,0.05)}
            .entry .name{color:#d4d4d4;word-break:break-all;flex:1;min-width:0}
            .entry.dir .name{color:#569cd6}
            .entry .size{
                color:#808080;margin-left:16px;white-space:nowrap;
                flex-shrink:0;
            }
            .empty{
                color:#808080;font-style:italic;text-align:center;
                padding:40px;font-size:13px;
            }
        </style></head>
        <body>
            <div class="header">
                <div class="filename">\(escapeHTML(filename))</div>
                <div class="summary">\(totalFiles) files, \(totalDirs) directories</div>
            </div>
            \(rows)
        </body>
        </html>
        """
    }

    private func errorPageHTML(message: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,sans-serif;background:#1e1e1e;color:#888;
                 display:flex;align-items:center;justify-content:center;height:100vh;
                 padding:40px;text-align:center;font-size:14px}
        </style></head><body><p>\(escapeHTML(message))</p></body></html>
        """
    }

    // MARK: - Utilities

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func escapeHTML(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
