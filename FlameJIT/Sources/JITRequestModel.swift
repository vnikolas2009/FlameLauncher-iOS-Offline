import Foundation
import Observation
import StikJIT
import UIKit

/// 무슨 일이 있었는지 파일로 남긴다 — 기기에서 os_log 를 꺼내기가 번거롭다
/// (최신 macOS 의 `log stream` 은 기기를 못 붙는다). devicectl 로 그대로 가져온다.
func jitNote(_ line: String) {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = documents.appending(path: "jitlog.txt")
    // ⚠️ 스크립트가 같은 줄을 초당 수천 번 뱉을 수 있다(붙지 못했을 때). 파일이 183MB 까지
    //    불어난 적이 있어 상한을 둔다 — 진단에 필요한 건 앞부분과 마지막 상태뿐이다.
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
       size > 1_000_000 {
        return
    }
    let stamped = "\(Date()) \(line)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(stamped.utf8))
        try? handle.close()
    } else {
        try? Data(stamped.utf8).write(to: url, options: .atomic)
    }
}

/// `flamejit://enable-jit?...` 한 건을 처리한다.
///
/// 받는 값:
///   bundle-id  켜 줄 앱(표시용 + 안전장치). 우리 앱이 아니면 거절한다.
///   pid        **실제 대상**. 런처가 자기 getpid() 를 보낸다.
///   pairing    RPPairing 파일 base64. 런처가 키체인에 들고 있다가 그때그때 넘긴다.
///   script     JIT 스크립트 base64(없으면 StikJIT 내장 universal).
///   return     끝나고 돌아갈 URL 스킴.
@Observable
@MainActor
final class JITRequestModel {
    var title = String(localized: "대기 중")
    var detail = String(localized: "FlameLauncher 가 JIT 를 요청하면 여기서 처리합니다.")
    var isWorking = false

    /// ⚠️ URL 스킴은 **아무 앱이나** 부를 수 있다. 임의의 PID 에 디버거를 붙여 주는 도구가
    ///    되지 않도록, 우리 런처가 보낸 요청만 받는다.
    private static let allowedBundlePrefix = "kr.co.donghyun.flamelauncher"

    /// StikJIT 의 작업은 **동기이고 블로킹**이다(통합 문서). 전용 직렬 큐에서만 돌린다.
    private let queue = DispatchQueue(label: "kr.co.donghyun.flamejit.work")

    func handle(_ url: URL) {
        guard url.host == "enable-jit",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return }
        let value = { (name: String) in parts.first { $0.name == name }?.value }

        guard let bundleID = value("bundle-id"), bundleID.hasPrefix(Self.allowedBundlePrefix) else {
            return fail(String(localized: "이 앱은 FlameLauncher 의 요청만 처리합니다."))
        }
        guard let pid = value("pid").flatMap(Int32.init) else {
            return fail(String(localized: "요청에 PID 가 없습니다."))
        }
        guard let pairing = value("pairing").flatMap({ Data(base64Encoded: $0) }) else {
            return fail(String(localized: "페어링 파일이 오지 않았습니다. 런처 설정에서 먼저 넣어 주세요."))
        }
        let script = value("script").flatMap { Data(base64Encoded: $0) }
        let returnScheme = value("return")

        jitNote("요청 받음 — pid=\(pid), 페어링 \(pairing.count)바이트, 스크립트 \(script == nil ? "없음" : "포함")")
        title = String(localized: "JIT 를 켜는 중")
        detail = String(localized: "기기 터널을 열고 디버거를 붙이고 있습니다…")
        isWorking = true
        enable(pid: pid, pairing: pairing, script: script, returnScheme: returnScheme)
    }

    // MARK: - 안쪽

    private func enable(pid: Int32, pairing: Data, script: Data?, returnScheme: String?) {
        // ⚠️ 스크립트는 **게임이 뜰 때까지** 붙어 있어야 한다(JVM 이 코드 캐시를 잡을 때마다
        //    brk 로 들어온다). 그래서 enableJIT 가 끝나기를 기다렸다 돌아가면 안 된다 —
        //    실측: "Handling signal 1" 에서 멈춘 채 런처로 영영 안 돌아갔다.
        //    붙는 순간(attach_response) 바로 돌려보내고, 우리는 백그라운드에서 계속 응답한다.
        let task = UIApplication.shared.beginBackgroundTask(withName: "flamejit.attach")
        var returned = false

        queue.async {
            let result = Self.run(pid: pid, pairing: pairing, script: script) { line in
                jitNote("진행: \(line)")
                if !returned, line.hasPrefix("attach_response = T") {
                    returned = true
                    Task { @MainActor in
                        self.title = String(localized: "JIT 켜짐")
                        self.detail = String(localized: "런처로 돌아갑니다. 이 앱은 게임이 뜰 때까지 뒤에서 응답합니다.")
                        self.goBack(to: returnScheme, ok: true)
                    }
                }
                Task { @MainActor in self.detail = line }
            }
            Task { @MainActor in
                self.isWorking = false
                switch result {
                case .success:
                    jitNote("스크립트 종료(성공)")
                    self.title = String(localized: "JIT 켜짐")
                    self.detail = String(localized: "끝났습니다.")
                case .failure(let error):
                    jitNote("실패 — \(error)")
                    self.title = String(localized: "JIT 를 켜지 못했습니다")
                    self.detail = error
                }
                if !returned { self.goBack(to: returnScheme, ok: result.isSuccess) }
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    /// 실제 호출. 받은 데이터는 **임시 파일로만** 쓰고 끝나면 바로 지운다(문서 권고).
    private static func run(pid: Int32, pairing: Data, script: Data?,
                            progress: @escaping (String) -> Void) -> Outcome {
        let tmp = FileManager.default.temporaryDirectory
        let pairingURL = tmp.appending(path: "pairing-\(UUID().uuidString).plist")
        let scriptURL = script.map { _ in tmp.appending(path: "script-\(UUID().uuidString).js") }
        defer {
            try? FileManager.default.removeItem(at: pairingURL)
            if let scriptURL { try? FileManager.default.removeItem(at: scriptURL) }
        }
        do {
            try pairing.write(to: pairingURL, options: .atomic)
            if let scriptURL, let script { try script.write(to: scriptURL, options: .atomic) }

            // DDI 캐시는 이 앱의 Library 에 둔다 — 한 번 마운트하면 재부팅 전까지 유지된다.
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let paths = DDIPaths.default(in: library.appending(path: "StikJIT"))

            try StikJIT.enableJIT(
                targetPID: pid,
                pairingFile: pairingURL,
                ddiPaths: paths,
                script: scriptURL.map { StikJIT.Script.custom($0) } ?? .universal,
                preparationProgress: { progress(describe($0)) },
                progress: progress
            )
            return .success
        } catch {
            return .failure(explain(error))
        }
    }

    /// 원문 오류를 그대로 보여 주면 사용자가 할 일을 모른다 — 가장 흔한 둘은 번역한다.
    ///
    /// ⚠️ 터널(10.7.0.1)은 **LocalDevVPN 이 만든다.** StikJIT 은 거기에 붙을 뿐이고,
    ///    우리가 직접 만들려면 Network Extension 권한이 필요한데 그건 유료 개발자
    ///    계정에만 열린다. StikDebug 도 같은 VPN 을 요구한다.
    private static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("10.7.0.1") || text.lowercased().contains("timed out connecting") {
            return String(localized: "LocalDevVPN 이 연결돼 있지 않습니다. App Store 에서 LocalDevVPN 을 설치하고 연결한 뒤 다시 시도해 주세요. (기기 안의 디버그 터널을 그 앱이 만듭니다)")
        }
        if text.lowercased().contains("pairing") {
            return String(localized: "페어링 파일을 기기가 거절했습니다. 런처 설정에서 새 파일로 교체해 주세요.")
        }
        return text
    }

    private static func describe(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability: return String(localized: "기기에 닿는지 확인 중…")
        case .checkingDDI:          return String(localized: "개발자 디스크 이미지 확인 중…")
        case .downloadingDDI(let fraction, _):
            return String(localized: "개발자 디스크 이미지 내려받는 중… \(Int(fraction * 100))%")
        case .mountingDDI:          return String(localized: "개발자 디스크 이미지 마운트 중…")
        case .verifyingDDI:         return String(localized: "마운트 확인 중…")
        case .ready:                return String(localized: "준비됨")
        @unknown default:           return String(localized: "준비 중…")
        }
    }

    private func goBack(to scheme: String?, ok: Bool) {
        guard let scheme, let url = URL(string: "\(scheme)://jit-done?ok=\(ok ? 1 : 0)") else { return }
        // 실패했으면 사유를 읽을 틈을 준다 — 성공은 바로 돌려보낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.3 : 2.5)) {
            UIApplication.shared.open(url)
        }
    }

    private func fail(_ message: String) {
        jitNote("거절 — \(message)")
        title = String(localized: "요청을 처리할 수 없습니다")
        detail = message
        isWorking = false
    }

    private enum Outcome {
        case success
        case failure(String)
        var isSuccess: Bool { if case .success = self { return true }; return false }
    }
}
