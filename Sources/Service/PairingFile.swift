import Foundation

/// JIT 페어링 파일을 **런처가 직접 들고 있는다.**
///
/// ⚠️ 왜 키체인인가. 앱을 다시 깔면 컨테이너가 통째로 지워져서, 그때마다 맥에서
///    `idevice-tools rppairing pair` 로 새로 만들어 넣어야 했다. 키체인 항목은 재설치를
///    넘겨 살아남으므로, **한 번만** 넣으면 그 뒤로는 앱이 알아서 되살린다.
///
/// 받아들이는 경로는 셋이고 전부 같은 곳으로 모인다:
///   1. 맥에서 `devicectl ... copy to Documents/pairingFile.plist`
///   2. 파일 앱(파일 공유)으로 Documents 에 떨군 `*.plist` / `*.mobiledevicepairing`
///   3. 앱 안에서 고른 파일(문서 선택기)
enum PairingFile {
    /// StikJIT 가 기대하는 자리 — 내장 JIT 로 넘어가도 그대로 쓴다(INTEGRATION.md).
    static var url: URL { Paths.external.appending(path: "StikJIT/pairingFile.plist") }

    private static let service = "kr.co.donghyun.flamelauncher.pairing"
    private static let account = "rppairing"

    /// 지금 쓸 수 있는 페어링 파일이 있는가.
    static var isReady: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 앱이 뜰 때 한 번 부른다. 밖에서 들어온 파일을 거두고, 없으면 키체인에서 되살린다.
    @discardableResult
    static func restoreIfNeeded() -> Bool {
        if let dropped = findDropped() {
            adopt(dropped)
            return true
        }
        if isReady { return true }
        guard let saved = Keychain.load(service: service, account: account) else { return false }
        write(saved)
        return true
    }

    /// 사용자가 문서 선택기로 고른 파일을 받아들인다.
    @discardableResult
    static func importFile(at source: URL) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source), isPairing(data) else { return false }
        write(data)
        Keychain.save(data, service: service, account: account)
        return true
    }

    // MARK: - 안쪽

    /// Documents 에 떨어진 페어링 파일(맥에서 복사했거나 파일 앱으로 넣은 것).
    ///
    /// ⚠️ 이름으로만 거르지 않는다 — devicectl 로 넣을 때 쓰는 `pairingFile.plist`,
    ///    파일 앱에서 넣는 `*.mobiledevicepairing` 등 이름이 제각각이라 **내용으로** 가린다.
    private static func findDropped() -> URL? {
        let documents = Paths.external
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil)) ?? []
        return entries.first { entry in
            guard ["plist", "mobiledevicepairing"].contains(entry.pathExtension),
                  let data = try? Data(contentsOf: entry)
            else { return false }
            return isPairing(data)
        }
    }

    private static func adopt(_ source: URL) {
        guard let data = try? Data(contentsOf: source) else { return }
        write(data)
        Keychain.save(data, service: service, account: account)
        // 거뒀으면 원본은 치운다 — Documents 에 그대로 두면 다음 실행마다 다시 읽는다.
        try? FileManager.default.removeItem(at: source)
    }

    private static func write(_ data: Data) {
        Paths.ensureDir(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    /// RPPairing 파일인가. **lockdown 페어 기록(DeviceCertificate…)은 안 된다** — 터널이
    /// `missing field 'public_key'` 로 거절한다(실측). 그래서 키 하나를 직접 본다.
    private static func isPairing(_ data: Data) -> Bool {
        guard data.count < 64 * 1024,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return plist["public_key"] != nil
    }
}
