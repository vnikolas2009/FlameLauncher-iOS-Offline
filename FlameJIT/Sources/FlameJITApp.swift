import SwiftUI

/// FlameJIT — FlameLauncher 전용 JIT 도우미.
///
/// ⚠️ 왜 **따로 뜨는 앱**인가. 디버거를 자기 자신에게 붙이면 교착한다(StikJIT 통합 문서).
///    런처 안에 넣는 길(도우미 앱 익스텐션)은 `AppExtensionProcess` 가 **iOS 26+** 라
///    아이패드(18.x)에서 못 쓴다. 별도 앱이면 iOS 17.4+ 어디서나 된다.
///
/// 하는 일은 하나다: 런처가 URL 로 건네준 PID·페어링 파일·스크립트로 JIT 를 켜고 돌아간다.
/// 보관하는 상태가 없다 — 페어링 파일은 런처가 들고 있고(키체인), 여기로는 요청마다 온다.
@main
struct FlameJITApp: App {
    @State private var model = JITRequestModel()

    var body: some Scene {
        WindowGroup {
            StatusView(model: model)
                .onOpenURL { model.handle($0) }
        }
    }
}

private struct StatusView: View {
    @Bindable var model: JITRequestModel

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("🔥").font(.system(size: 44))
                Text(model.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text(model.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                if model.isWorking { ProgressView().tint(.orange) }
            }
        }
    }
}
