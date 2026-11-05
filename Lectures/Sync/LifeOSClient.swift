import Foundation
import Observation
import Security

struct Course: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var code: String

    /// Short label for chips: the course code when Canvas has one.
    var short: String { code.isEmpty ? name : code }
}

enum LifeOSError: LocalizedError {
    case notConnected, wrongPasscode(left: Int?), lockedOut, notConfigured, server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect LifeOS in Settings first."
        case .wrongPasscode(let left): left.map { "Wrong passcode - \($0) tries left." } ?? "Wrong passcode."
        case .lockedOut: "Too many tries. Wait a few minutes and try again."
        case .notConfigured: "The LifeOS passcode lock isn't set up on the server."
        case .server(let m): m
        }
    }
}

/// Talks to the LifeOS server (the same Vercel app as the LifeOS PWA).
/// Auth = the LifeOS widget key, handed out once by the passcode unlock and
/// kept in the Keychain - the passcode itself is never stored.
@MainActor
@Observable
final class LifeOSClient {
    static let base = URL(string: "https://lifeos-phi-ochre.vercel.app")!

    private(set) var isConnected = Keychain.read() != nil
    private(set) var courses: [Course] = LifeOSClient.cachedCourses()

    // MARK: connect

    func connect(passcode: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("api/unlock"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": passcode, "purpose": "widget"])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200:
            guard let key = json["widgetKey"] as? String, !key.isEmpty else { throw LifeOSError.server("No key came back.") }
            Keychain.save(key)
            isConnected = true
            await refreshCourses()
        case 401: throw LifeOSError.wrongPasscode(left: json["left"] as? Int)
        case 429: throw LifeOSError.lockedOut
        case 503: throw LifeOSError.notConfigured
        default: throw LifeOSError.server("LifeOS answered \(status).")
        }
    }

    func disconnect() {
        Keychain.delete()
        isConnected = false
    }

    // MARK: courses (active Canvas courses, cached for offline lecture halls)

    func refreshCourses() async {
        guard let data = try? await call("GET", query: [URLQueryItem(name: "courses", value: "1")]),
              let body = try? JSONDecoder().decode(CoursesBody.self, from: data) else { return }
        courses = body.courses.sorted { $0.short < $1.short }
        if let saved = try? JSONEncoder().encode(courses) { UserDefaults.standard.set(saved, forKey: "courses") }
    }

    private struct CoursesBody: Decodable { var courses: [Course] }

    private static func cachedCourses() -> [Course] {
        guard let data = UserDefaults.standard.data(forKey: "courses") else { return [] }
        return (try? JSONDecoder().decode([Course].self, from: data)) ?? []
    }

    // MARK: lectures

    func upload(_ lecture: Lecture) async throws {
        let body: [String: Any] = [
            "id": lecture.id.uuidString,
            "courseId": lecture.courseId ?? "",
            "course": lecture.courseName,
            "title": lecture.title,
            "recordedAt": ISO8601DateFormatter().string(from: lecture.recordedAt),
            "durationSec": Int(lecture.durationSec),
            "transcript": lecture.transcript,
            "engine": lecture.engine,
        ]
        _ = try await call("POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    func remove(_ id: UUID) async throws {
        _ = try await call("DELETE", query: [URLQueryItem(name: "id", value: id.uuidString)])
    }

    // MARK: plumbing

    private func call(_ method: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let key = Keychain.read() else { throw LifeOSError.notConnected }
        var url = URLComponents(url: Self.base.appendingPathComponent("api/lectures"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var req = URLRequest(url: url.url!)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue(key, forHTTPHeaderField: "x-lifeos-widget")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // the widget key was rotated on the server
            disconnect()
            throw LifeOSError.server("LifeOS signed this app out - reconnect in Settings.")
        }
        guard (200..<300).contains(status) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw LifeOSError.server(message ?? "LifeOS answered \(status).")
        }
        return data
    }
}

/// The widget key, in the Keychain (survives reinstalls of TestFlight builds).
enum Keychain {
    private static let service = "com.cmoney0.lectures.lifeos"

    static func save(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
