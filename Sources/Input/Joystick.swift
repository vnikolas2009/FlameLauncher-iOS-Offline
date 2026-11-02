import CoreGraphics

/// 가상 스틱의 방향 → WASD 변환. 게임 화면(GameControlsView)과 테스트가 같은 함수를 쓴다.
enum Joystick {
    static let w = 87, a = 65, s = 83, d = 68

    /// 각도를 8방위로 양자화해 W/A/S/D 조합을 만든다.
    /// 화면 좌표계라 위쪽이 -y — 각도 0 은 오른쪽(D)이다.
    static func keys(forAngle angle: CGFloat) -> Set<Int> {
        // 한 식으로 쓰면 Xcode 26 의 타입 검사기가 시간 초과로 포기한다(CGFloat 리터럴 추론).
        let full: CGFloat = 2 * CGFloat.pi
        let half: CGFloat = CGFloat.pi / 8
        let step: CGFloat = CGFloat.pi / 4
        let shifted: CGFloat = angle + full + half
        let sector = Int((shifted / step).rounded(.down)) % 8
        switch sector {
        case 0: return [d]
        case 1: return [d, s]
        case 2: return [s]
        case 3: return [s, a]
        case 4: return [a]
        case 5: return [a, w]
        case 6: return [w]
        default: return [w, d]
        }
    }
}
