import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum PlaybackPhase: Equatable {
    case loading
    case ready
    case playing
    case paused
    case buffering
    case finished
    case failed(String)
}

enum PlayerDisplayMode: String, Equatable {
    case fit
    case zoom

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit:
            .resizeAspect
        case .zoom:
            .resizeAspectFill
        }
    }

    var title: String {
        switch self {
        case .fit:
            "Fit entire video"
        case .zoom:
            "Zoom to fill"
        }
    }

    var symbol: String {
        switch self {
        case .fit:
            "arrow.down.right.and.arrow.up.left"
        case .zoom:
            "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct PlayerTrackOption: Identifiable, Equatable {
    let id: String
    let title: String
}

enum PlayerHUDKind: Equatable {
    case brightness
    case volume
}

struct PlayerHUDState: Identifiable, Equatable {
    let id = UUID()
    let kind: PlayerHUDKind
    let value: Double
}

enum PlayerSeekDirection: Equatable {
    case backward
    case forward
}

struct PlayerSeekFeedback: Identifiable, Equatable {
    let id = UUID()
    let direction: PlayerSeekDirection
}

enum PlayerTimeText {
    static func string(_ rawSeconds: Double) -> String {
        let seconds = max(Int(rawSeconds.isFinite ? rawSeconds : 0), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

@MainActor
enum PlayerOrientation {
    static func toggle(isCurrentlyLandscape: Bool) {
        request(isCurrentlyLandscape ? .portrait : .landscape)
    }

    static func restoreAppOrientations() {
        request(.allButUpsideDown)
    }

    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("Player orientation update failed: \(error.localizedDescription)")
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

struct SystemVolumeBridge: UIViewRepresentable {
    let volume: Float

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else {
            return
        }
        let target = min(max(volume, 0), 1)
        guard abs(slider.value - target) > 0.005 else { return }
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

@MainActor
enum PlaybackProgressStore {
    private static let storageKey = "dropframe.playback-progress.v1"

    static func position(for videoID: UUID) -> Double {
        positions()[videoID.uuidString] ?? 0
    }

    static func save(_ position: Double, for videoID: UUID) {
        var values = positions()
        values[videoID.uuidString] = max(position, 0)
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    static func removePosition(for videoID: UUID) {
        var values = positions()
        values.removeValue(forKey: videoID.uuidString)
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    private static func positions() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
