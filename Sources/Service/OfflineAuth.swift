import Foundation
import UIKit
import CryptoKit
import Observation

/// 오프라인 계정. 마이크로소프트/모장 로그인은 없다 — 닉네임 하나가 전부다.
///
/// 필드 이름(`username` / `uuid` / `accessToken`)은 `GameLauncher` 가 그대로 쓰므로 유지했다.
/// 토큰은 서버에 검증받는 값이 아니라 자리 채움 `"0"` 이다.
struct AuthSession: Codable, Equatable {
    var username: String
    /// 하이픈 없는 32자 UUID. 바닐라 오프라인 방식(`OfflinePlayer:<닉네임>` 의 MD5, v3)과 같게 만든다.
    /// → 같은 닉네임이면 항상 같은 UUID 라서 월드의 플레이어 데이터가 유지된다.
    var uuid: String
    var accessToken: String { "0" }

    init(username: String) {
        self.username = username
        self.uuid = Self.offlineUUID(for: username)
    }

    private enum CodingKeys: String, CodingKey { case username, uuid }

    /// 스킨 얼굴. 오프라인 계정은 UUID 가 가짜라 **닉네임**으로 조회한다
    /// (같은 이름의 정품 계정이 있으면 그 스킨이 보인다 — 실제 서버에서도 똑같이 보인다).
    var faceURL: URL? {
        username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "https://mc-heads.net/avatar/\($0)/128") }
    }

    /// 바닐라 `UUID.nameUUIDFromBytes("OfflinePlayer:" + name)` 와 같은 값.
    nonisolated static func offlineUUID(for name: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30     // version 3
        bytes[8] = (bytes[8] & 0x3f) | 0x80     // IETF variant
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// 닉네임 저장·검증·입력창. 네트워크는 전혀 쓰지 않는다.
@Observable @MainActor
final class AuthStore: NSObject {
    static let shared = AuthStore()

    private static let defaultsKey = "flamelauncher.offlineNickname"
    /// 마인크래프트 닉네임 규칙: 3~16자, 영문·숫자·밑줄.
    private static let namePattern = "^[A-Za-z0-9_]{3,16}$"

    private(set) var session: AuthSession?

    var isLoggedIn: Bool { session != nil }
    var username: String? { session?.username }
    var uuid: String? { session?.uuid }

    private var isPrompting = false

    override init() {
        super.init()
        restore()
    }

    nonisolated static func isValidNickname(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    /// 저장된 닉네임을 읽는다. 예전 빌드의 Microsoft 세션이 키체인에 남아 있으면 지운다
    /// (토큰이 기기에 계속 남을 이유가 없다).
    func restore() {
        Keychain.delete(service: "kr.co.donghyun.flamelauncher.auth", account: "microsoft-session")
        if let name = UserDefaults.standard.string(forKey: Self.defaultsKey),
           Self.isValidNickname(name) {
            session = AuthSession(username: name)
        }
    }

    /// 닉네임을 저장한다. 규칙에 안 맞으면 false.
    @discardableResult
    func setNickname(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidNickname(name) else { return false }
        UserDefaults.standard.set(name, forKey: Self.defaultsKey)
        session = AuthSession(username: name)
        return true
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        session = nil
    }

    /// 닉네임 입력창을 띄운다. 이름은 예전 로그인 흐름과 맞춰 둔 것이다 —
    /// 호출하는 쪽(`play()` 등)은 "계정이 없으면 만든다" 로만 알면 된다.
    func login() async {
        guard !isPrompting else { return }
        isPrompting = true
        defer { isPrompting = false }
        guard let name = await promptNickname(initial: username) else { return }
        setNickname(name)
    }

    // MARK: - 입력창

    private func promptNickname(initial: String?) async -> String? {
        guard let presenter = Self.topViewController() else { return nil }

        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: String(localized: "닉네임 입력"),
                message: String(localized: "오프라인 계정으로 플레이합니다.\n3~16자, 영문·숫자·밑줄만 쓸 수 있습니다."),
                preferredStyle: .alert)

            var ok: UIAlertAction!
            alert.addTextField { field in
                field.placeholder = String(localized: "닉네임")
                field.text = initial
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.spellCheckingType = .no
                field.clearButtonMode = .whileEditing
                field.returnKeyType = .done
                // 규칙에 안 맞으면 확인 버튼을 꺼 둔다 — 눌러 놓고 오류를 보는 것보다 낫다.
                field.addAction(UIAction { [weak field] _ in
                    ok.isEnabled = Self.isValidNickname((field?.text ?? "").trimmingCharacters(in: .whitespaces))
                }, for: .editingChanged)
            }
            ok = UIAlertAction(title: String(localized: "확인"), style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            ok.isEnabled = Self.isValidNickname((initial ?? "").trimmingCharacters(in: .whitespaces))
            alert.addAction(UIAlertAction(title: String(localized: "취소"), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(ok)
            alert.preferredAction = ok
            presenter.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
