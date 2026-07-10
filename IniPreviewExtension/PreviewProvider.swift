import QuickLookUI
import UniformTypeIdentifiers
import AppKit

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let fileURL = request.fileURL

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            completionHandler(nil, NSError(domain: "IniPreviewError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not read file as UTF-8 text"]))
            return
        }

        let html = generateHTML(from: content, filename: fileURL.lastPathComponent)

        guard let data = html.data(using: .utf8) else {
            completionHandler(nil, NSError(domain: "IniPreviewError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
            return
        }

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { reply in
            return data
        }

        completionHandler(reply, nil)
    }

    // MARK: - INI Parsing & HTML Generation

    private struct Section {
        let name: String
        let pairs: [(key: String, value: String)]
        let comments: [String]
    }

    private func parseINI(_ content: String) -> [Section] {
        var sections: [Section] = []
        var currentSectionName = ""
        var currentPairs: [(String, String)] = []
        var currentComments: [String] = []

        let lines = content.components(separatedBy: .newlines)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                currentComments.append(comment)
                continue
            }

            if trimmed.hasPrefix("[") {
                let sectionName = trimmed
                    .trimmingCharacters(in: .whitespaces)
                    .dropFirst()
                    .dropLast()
                    .trimmingCharacters(in: .whitespaces)

                if !currentSectionName.isEmpty || !currentPairs.isEmpty || !currentComments.isEmpty {
                    sections.append(Section(name: currentSectionName, pairs: currentPairs, comments: currentComments))
                }
                currentSectionName = String(sectionName)
                currentPairs = []
                currentComments = []
                continue
            }

            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
                currentPairs.append((key, value))
            }
        }

        if !currentSectionName.isEmpty || !currentPairs.isEmpty || !currentComments.isEmpty {
            sections.append(Section(name: currentSectionName, pairs: currentPairs, comments: currentComments))
        }

        return sections
    }

    private func generateHTML(from content: String, filename: String) -> String {
        let sections = parseINI(content)

        let sectionsHTML = sections.isEmpty
            ? "<div class=\"empty\">Empty INI file</div>"
            : sections.map { section -> String in
                var html = "<div class=\"section\">"
                if !section.name.isEmpty {
                    html += "<div class=\"section-header\">[\(escapeHTML(section.name))]</div>"
                }
                for comment in section.comments {
                    html += "<div class=\"comment\">; \(escapeHTML(comment))</div>"
                }
                for pair in section.pairs {
                    html += """
                    <div class="pair">
                        <span class="key">\(escapeHTML(pair.key))</span>
                        <span class="separator"> = </span>
                        <span class="value">\(escapeHTML(pair.value))</span>
                    </div>
                    """
                }
                html += "</div>"
                return html
            }.joined()

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, 'SF Mono', Menlo, Monaco, 'Courier New', monospace;
                font-size: 13px;
                background: #1e1e1e;
                color: #d4d4d4;
                padding: 24px;
            }
            .header {
                border-bottom: 1px solid #333;
                padding-bottom: 12px;
                margin-bottom: 20px;
            }
            .filename {
                color: #569cd6;
                font-size: 15px;
                font-weight: 600;
            }
            .section {
                margin: 0 0 12px 0;
                padding: 10px 14px;
                background: #252526;
                border-left: 3px solid #569cd6;
                border-radius: 4px;
            }
            .section-header {
                color: #569cd6;
                font-weight: 700;
                font-size: 14px;
                margin-bottom: 8px;
            }
            .pair {
                margin: 3px 0 3px 14px;
                display: flex;
                gap: 4px;
            }
            .key { color: #9cdcfe; }
            .separator { color: #808080; }
            .value { color: #ce9178; word-break: break-all; }
            .comment {
                color: #6a9955;
                font-style: italic;
                margin: 2px 0 2px 14px;
            }
            .empty {
                color: #808080;
                font-style: italic;
                padding: 20px;
                text-align: center;
            }
        </style>
        </head>
        <body>
        <div class="header">
            <div class="filename">\(escapeHTML(filename))</div>
        </div>
        \(sectionsHTML)
        </body>
        </html>
        """
    }

    private func escapeHTML(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}
