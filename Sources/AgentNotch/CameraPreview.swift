import AVFoundation
import SwiftUI

/// Drives the webcam feed behind the Dashboard's mirror widget.
///
/// The capture session runs only while the widget is actually on screen:
/// the widget calls `addViewer()`/`removeViewer()` as it appears and
/// disappears, and the session stops as soon as the count hits zero. That
/// keeps the camera's indicator light tied to something the user can see —
/// it never runs because the app merely happens to be launched.
@MainActor
final class CameraPreviewController: ObservableObject {
    static let shared = CameraPreviewController()

    @Published private(set) var isRunning = false
    /// Non-nil when the feed can't be shown — no camera, access denied, or
    /// a configuration failure. Rendered in place of the picture.
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    private var isConfigured = false
    private var viewerCount = 0

    private init() {}

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func addViewer() {
        viewerCount += 1
        guard viewerCount == 1 else { return }
        start()
    }

    func removeViewer() {
        viewerCount = max(0, viewerCount - 1)
        guard viewerCount == 0 else { return }
        stop()
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    // Only restart if something is still watching — the user
                    // may have closed the panel while the prompt was up.
                    if self.viewerCount > 0 { self.start() }
                } else {
                    self.errorMessage = String(localized: "camera.accessDenied", defaultValue: "Camera access denied")
                }
            }
        }
    }

    private func start() {
        switch authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            requestAccess()
            return
        default:
            errorMessage = String(localized: "camera.accessDenied", defaultValue: "Camera access denied")
            return
        }

        guard configureIfNeeded() else { return }
        guard !session.isRunning else { return }
        // `startRunning()` blocks until the device is ready, which is long
        // enough to drop frames on the main thread.
        let session = session
        Task.detached(priority: .userInitiated) {
            session.startRunning()
            await MainActor.run { [weak self] in
                self?.isRunning = session.isRunning
            }
        }
    }

    private func stop() {
        guard session.isRunning else { return }
        let session = session
        isRunning = false
        Task.detached(priority: .utility) {
            session.stopRunning()
        }
    }

    /// Built once and reused: reconfiguring on every appearance would make
    /// the camera light flicker each time the panel opens.
    private func configureIfNeeded() -> Bool {
        guard !isConfigured else { return true }
        guard let device = AVCaptureDevice.default(for: .video) else {
            errorMessage = String(localized: "camera.noCamera", defaultValue: "No camera found")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            // Low-res is plenty for a widget a few hundred points wide, and
            // costs meaningfully less power than the default preset.
            session.sessionPreset = .low
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                errorMessage = String(localized: "camera.unavailable", defaultValue: "Camera unavailable")
                return false
            }
            session.addInput(input)
            session.commitConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        isConfigured = true
        errorMessage = nil
        return true
    }
}

/// Hosts the capture session's preview layer. A plain `NSView` with a
/// layer rather than `VideoPlayer`/`AVPlayerLayer` — a live capture session
/// has no player to speak of.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        // Mirrored, because this is a mirror: an unmirrored self-view moves
        // the wrong way when you do.
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The layer's frame follows the hosting view automatically; nothing
        // here depends on SwiftUI state.
    }
}
