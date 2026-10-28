import Foundation
import UniformTypeIdentifiers

enum UploadError: LocalizedError {
    case badResponse(Int)
    case noURLInResponse
    case emptyData
    case unauthorized
    case noDestination

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return String(localized: "The upload failed (HTTP \(code)).")
        case .noURLInResponse: return String(localized: "The server’s response had no URL in it.")
        case .emptyData: return String(localized: "The file is empty.")
        case .unauthorized: return String(localized: "The file server rejected your credentials (HTTP 401).")
        case .noDestination: return String(localized: "Nowhere to upload to: this network offers no FILEHOST and no custom uploader is set in Settings.")
        }
    }
}

/// The IRC server's own upload endpoint (`draft/FILEHOST` / `soju.im/FILEHOST`)
/// with the HTTP Basic credentials the spec asks for under SASL PLAIN.
struct FileHostTarget: Sendable {
    var url: URL
    var basicUser: String?
    var basicPassword: String?
}

/// A pastebin/0x0-style uploader configured by the user.
struct CustomUploader: Sendable {
    enum Response: Sendable { case text, location, json(String) }
    var url: URL
    /// Multipart field name; empty sends the raw bytes as the body.
    var field: String
    var token: String
    var response: Response

    @MainActor init?(_ prefs: Preferences) {
        guard let url = URL(string: prefs.uploaderURL.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        self.url = url
        field = prefs.uploaderField
        token = prefs.uploaderToken
        let kind = prefs.uploaderResponse
        if kind == "location" { response = .location }
        else if kind.hasPrefix("json") {
            let key = kind.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "url"
            response = .json(key.isEmpty ? "url" : key)
        } else { response = .text }
    }
}

enum UploadDestination: Sendable {
    case server(FileHostTarget)
    case custom(CustomUploader)
}

enum Uploader {
    static func upload(fileAt url: URL, to destination: UploadDestination) async throws -> String {
        let data = try Data(contentsOf: url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return try await upload(data: data, filename: url.lastPathComponent, mimeType: mime, to: destination)
    }

    static func upload(data: Data, filename: String, mimeType: String,
                       to destination: UploadDestination) async throws -> String {
        guard !data.isEmpty else { throw UploadError.emptyData }
        switch destination {
        case let .server(host): return try await upload(data: data, filename: filename, mimeType: mimeType, fileHost: host)
        case let .custom(config): return try await upload(data: data, filename: filename, mimeType: mimeType, custom: config)
        }
    }

    /// FILEHOST: raw bytes as the body; the URL comes back in `Location`.
    private static func upload(data: Data, filename: String, mimeType: String,
                               fileHost: FileHostTarget) async throws -> String {
        var request = URLRequest(url: fileHost.url)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentDisposition(filename), forHTTPHeaderField: "Content-Disposition")
        if let user = fileHost.basicUser, let password = fileHost.basicPassword {
            let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        if code == 401 { throw UploadError.unauthorized }
        guard (200..<300).contains(code) else { throw UploadError.badResponse(code) }
        guard let location = http?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: fileHost.url) else { throw UploadError.noURLInResponse }
        return url.absoluteString
    }

    private static func upload(data: Data, filename: String, mimeType: String,
                               custom: CustomUploader) async throws -> String {
        var request = URLRequest(url: custom.url)
        request.httpMethod = "POST"
        if !custom.token.isEmpty { request.setValue("Bearer \(custom.token)", forHTTPHeaderField: "Authorization") }
        if custom.field.isEmpty {
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        } else {
            let boundary = "keryx-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(custom.field)\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
        }
        let (respData, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        if code == 401 { throw UploadError.unauthorized }
        guard (200..<300).contains(code) else { throw UploadError.badResponse(code) }
        let result: String?
        switch custom.response {
        case .text:
            result = String(data: respData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .location:
            result = http?.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: custom.url)?.absoluteString }
        case let .json(keyPath):
            result = extract(keyPath, from: respData)
        }
        guard let url = result, !url.isEmpty else { throw UploadError.noURLInResponse }
        return url
    }

    private static let attrChars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    private static func contentDisposition(_ filename: String) -> String {
        let ascii = String(filename.unicodeScalars.map {
            $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_"
        })
        var value = "inline; filename=\"\(ascii)\""
        if ascii != filename, let encoded = filename.addingPercentEncoding(withAllowedCharacters: attrChars) {
            value += "; filename*=UTF-8''\(encoded)"
        }
        return value
    }

    private static func extract(_ keyPath: String, from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var current: Any? = root
        for key in keyPath.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        if let string = current as? String { return string }
        return (current as? NSNumber)?.stringValue
    }
}
