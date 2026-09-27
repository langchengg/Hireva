import Foundation
import Darwin
import CryptoKit
import SwiftSoup

struct PublicRoleBrief: Codable {
    struct Excerpt: Codable { var location: String; var text: String }
    var url: String
    var fetchedAt: Date
    var sha256: String
    var title: String
    var excerpts: [Excerpt]
    var snapshot: String
    var markdown: String {
        "# \(title)\nSource: \(url)\nFetched: \(fetchedAt.formatted())\nScope: one user-provided page, not a web-wide search.\n\n## Public source excerpts (not independently verified)\n" + excerpts.prefix(16).map { "- [\($0.location)] \($0.text)" }.joined(separator: "\n") + "\n\n## Preparation questions (system suggestions, not source facts)\n- Which responsibilities are priorities in the first three months?\n- What evidence would demonstrate success?\n- Which requirements and working arrangements need confirmation?\n\nCompare these requirements with confirmed CV evidence in Documents. Page text cannot create personal accomplishments."
    }
}

enum PublicURLPolicy {
    static func validate(_ text: String) throws -> URL {
        guard text.utf8.count <= 2048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              !host.contains("%"), !host.contains(":"), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              !["localhost", "local", "internal", "test", "invalid"].contains(host),
              ![".localhost", ".local", ".internal"].contains(where: host.hasSuffix) else { throw MaterialError.invalid("Use a public HTTPS URL on port 443, without credentials or a fragment.") }
        // Literal hosts are disallowed, including alternate numeric IPv4 syntax.
        guard host.contains("."), host.split(separator: ".").last?.contains(where: { $0.isLetter }) == true else { throw MaterialError.invalid("Use a public DNS hostname, not an IP literal.") }
        return url
    }
    static func isPublicIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1], c = parts[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 { return false }
        if a == 192 && (b == 0 || b == 2 || b == 88 && c == 99) { return false }
        if a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return false }
        return true
    }
    static func resolvedIPv4(host: String) throws -> String {
        try Task.checkCancellation()
        // A child resolver can be cancelled and bounded; getaddrinfo can block
        // beyond the request budget. All returned addresses are checked before pinning.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Hireva-DNS-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MaterialError.invalid("Cannot create resolver output.") }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-q", "host", "-a", "name", host]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning {
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Task.isCancelled || Date() > deadline || size > 65536 {
                process.terminate(); process.waitUntilExit()
                try Task.checkCancellation()
                throw MaterialError.invalid("DNS exceeded time or size limit.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw MaterialError.invalid("DNS resolution failed.") }
        let response = try Data(contentsOf: output)
        guard response.count <= 65536 else { throw MaterialError.invalid("DNS exceeded size limit.") }
        let addresses = String(decoding: response, as: UTF8.self).components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("ip_address:") else { return nil }
            return line.dropFirst("ip_address:".count).trimmingCharacters(in: .whitespaces)
        }
        guard !addresses.isEmpty, addresses.allSatisfy(isPublicIPv4), let ip = addresses.first else { throw MaterialError.invalid("DNS returned no public IPv4 address or included a private/reserved address.") }
        return ip
    }
}

/// System curl is deliberately used as the bounded transport: --resolve pins the
/// checked address while retaining HTTPS hostname verification. URLSession's
/// independent DNS resolution would leave a DNS-rebinding check/use race here.
/// No shell, browser cookies, curl configuration, proxy, redirects or page links.
enum PublicRoleBriefService {
    static func fetch(_ text: String) throws -> PublicRoleBrief {
        let url = try PublicURLPolicy.validate(text)
        let host = url.host!
        let ip = try PublicURLPolicy.resolvedIPv4(host: host)
        try Task.checkCancellation()
        let robotsURL = URL(string: "https://\(host)/robots.txt")!
        let robots = try download(robotsURL, ip: ip, limit: 128000)
        if robots.status == 200 {
            guard robotsAllow(path: url.path.isEmpty ? "/" : url.path, content: String(decoding: robots.data, as: UTF8.self)) else { throw MaterialError.invalid("This site's robots policy does not allow this fetch.") }
        } else if robots.status != 404 && robots.status != 410 {
            throw MaterialError.invalid("Could not establish robots policy (HTTP \(robots.status)); supply text manually.")
        }
        let response = try download(url, ip: ip, limit: 2_000_000)
        guard response.status == 200 else { throw MaterialError.invalid("HTTP \(response.status). Redirects, login and access-controlled pages are not followed.") }
        guard response.type.lowercased().hasPrefix("text/html"), let html = String(data: response.data, encoding: .utf8) else { throw MaterialError.invalid("Expected UTF-8 HTML, within 2 MB.") }
        return try parse(html: html, url: url, fetchedAt: Date())
    }
    static func parse(html: String, url: URL, fetchedAt: Date) throws -> PublicRoleBrief {
        guard html.utf8.count <= 2_000_000 else { throw MaterialError.invalid("HTML exceeds size limit.") }
        let document = try SwiftSoup.parse(html, url.absoluteString)
        try document.select("script,style,noscript,iframe,form,nav,footer").remove()
        let nodes = try document.select("h1,h2,h3,p,li").array()
        let excerpts = try nodes.enumerated().compactMap { index, node -> PublicRoleBrief.Excerpt? in
            let text = try node.text()
            guard text.count >= 20 else { return nil }
            return .init(location: "HTML block \(index + 1)", text: String(text.prefix(1800)))
        }
        guard !excerpts.isEmpty else { throw MaterialError.invalid("No readable page body; the source is insufficient for a brief.") }
        return .init(url: url.absoluteString, fetchedAt: fetchedAt, sha256: SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined(), title: try document.title(), excerpts: Array(excerpts.prefix(100)), snapshot: html)
    }
    static func robotsAllow(path: String, content: String) -> Bool {
        // Conservative: apply all nonempty Disallow rules, even for other agents;
        // unsupported wildcard rules fail closed. No attempt to bypass a policy.
        for line in content.components(separatedBy: .newlines) {
            let clean = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let pair = clean.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "disallow", !pair[1].isEmpty {
                if pair[1].contains("*") || pair[1].contains("$") || path.hasPrefix(pair[1]) { return false }
            }
        }
        return true
    }
    private static func download(_ url: URL, ip: String, limit: Int) throws -> (data: Data, status: Int, type: String) {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hireva-fetch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = directory.appendingPathComponent("body")
        let metadata = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.arguments = ["-q", "--silent", "--globoff", "--proto", "=https", "--noproxy", "*", "--ipv4", "--resolve", "\(url.host!):443:\(ip)", "--max-redirs", "0", "--connect-timeout", "5", "--max-time", "15", "--max-filesize", String(limit), "--user-agent", "HirevaPublicBrief/1.0", "--output", body.path, "--write-out", "%{http_code}\n%{content_type}", "--url", url.absoluteString]
        process.standardOutput = metadata
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            if let size = try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { process.terminate(); process.waitUntilExit(); throw MaterialError.invalid("Response exceeded byte limit.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw MaterialError.invalid("Public-page fetch failed or exceeded time/size limit (transport \(process.terminationStatus)).") }
        let status = String(decoding: metadata.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).components(separatedBy: .newlines)
        let data = try Data(contentsOf: body)
        guard data.count <= limit else { throw MaterialError.invalid("Response exceeded byte limit.") }
        return (data, Int(status.first ?? "") ?? 0, status.dropFirst().first ?? "")
    }
}
