import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import UIKit

enum PairingQRCodeImageDecoder {
    enum DecodeError: LocalizedError, Equatable {
        case invalidImage
        case noCodeFound

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "That image could not be read."
            case .noCodeFound:
                return "No QR code was found in that image."
            }
        }
    }

    static func decodePayload(from imageData: Data) throws -> String {
        guard let ciImage = CIImage(data: imageData),
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else {
            throw DecodeError.invalidImage
        }
        if let payload = detector
            .features(in: ciImage)
            .compactMap({ ($0 as? CIQRCodeFeature)?.messageString?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return payload
        }
        throw DecodeError.noCodeFound
    }
}

private enum PairingScannerCameraState: Equatable {
    case checkingPermission
    case ready
    case denied
    case unavailable(String)

    var headline: String {
        switch self {
        case .checkingPermission:
            return "Checking camera access"
        case .ready:
            return "Point the camera at the QR on your computer"
        case .denied:
            return "Camera access is off"
        case let .unavailable(message):
            return message
        }
    }

    var detail: String {
        switch self {
        case .checkingPermission:
            return "MOBaiLE asks for camera access the first time you scan a pairing QR."
        case .ready:
            return "The app reads the code directly and opens the pairing confirmation right away."
        case .denied:
            return "Allow camera access in Settings, or pair from a screenshot or copied link instead."
        case .unavailable:
            return "Use a screenshot from Photos or paste the pairing link instead."
        }
    }

    var showsLiveCamera: Bool {
        switch self {
        case .checkingPermission, .ready:
            return true
        case .denied, .unavailable:
            return false
        }
    }
}

struct PairingScannerSheet: View {
    let isRepairMode: Bool
    let onSubmitPayload: (String) -> String?
    let onOpenManualSetup: () -> Void

#if targetEnvironment(simulator)
    @State private var cameraState: PairingScannerCameraState = .unavailable("Camera is not available on this device.")
#else
    @State private var cameraState: PairingScannerCameraState = .checkingPermission
#endif
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage = ""
    @State private var isProcessing = false
    @State private var scannerSessionID = UUID()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scannerHeader
                    scannerSurface
                    quickActionsSection
                    manualFallbackSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isRepairMode ? "Reconnect Phone" : "Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedPhotoItem) {
                guard let item = selectedPhotoItem else { return }
                Task {
                    await importPairingPhoto(item)
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private var scannerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isRepairMode ? "Reconnect from your computer" : "Pair from your computer", systemImage: "qrcode.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(
                isRepairMode
                    ? "Open the latest pairing QR on your computer, then scan it here to replace the saved connection."
                    : "Open the pairing QR on your computer, then scan it right here."
            )
                .font(.title3.weight(.semibold))

            Text(
                isRepairMode
                    ? "MOBaiLE keeps your server details and swaps in a fresh token after you confirm the new QR."
                    : "MOBaiLE fills the connection for you and asks for confirmation before it pairs."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scannerSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if cameraState.showsLiveCamera {
                    PairingCameraPreview(
                        cameraState: $cameraState,
                        onCodeScanned: handleScannedPayload
                    )
                    .id(scannerSessionID)
                    .overlay(alignment: .topLeading) {
                        if cameraState == .ready {
                            Label("Live scan", systemImage: "viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(14)
                            }
                    }
                    PairingScannerOverlay()
                        .allowsHitTesting(false)
                } else {
                    scannerPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .background(Color.black.opacity(cameraState.showsLiveCamera ? 1 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            if cameraState.showsLiveCamera {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cameraState.headline)
                        .font(.subheadline.weight(.semibold))
                    Text(cameraState.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !errorMessage.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)

                    if cameraState.showsLiveCamera {
                        Button("Try Again") {
                            errorMessage = ""
                            scannerSessionID = UUID()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var scannerPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(cameraState.headline)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)

            Text(cameraState.detail)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.74))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            if cameraState == .denied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .padding(24)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRepairMode ? "Other ways to reconnect" : "Other ways to pair")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pasteButton
                    photoPickerButton
                }

                VStack(spacing: 10) {
                    pasteButton
                    photoPickerButton
                }
            }

            Text(isRepairMode ? "Need a fresh QR? Run `mobaile pair` on your computer." : "Need the QR again? Run `mobaile pair` on your computer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var pasteButton: some View {
        Button {
            Task {
                await scanClipboard()
            }
        } label: {
            Label(isProcessing ? "Working..." : "Paste Link or QR", systemImage: "doc.on.clipboard")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isProcessing)
    }

    private var photoPickerButton: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Use a Screenshot", systemImage: "photo")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)
    }

    private var manualFallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isRepairMode ? "Manual reconnect" : "Manual fallback", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))

            Text(
                isRepairMode
                    ? "If scanning is not possible, you can still replace the saved server URL and token yourself in Settings."
                    : "If scanning is not possible, you can still enter the server URL and token yourself in Settings."
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Enter URL and Token Manually") {
                onOpenManualSetup()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    private func handleScannedPayload(_ payload: String) {
        errorMessage = ""
        if let error = onSubmitPayload(payload) {
            notify(.error)
            errorMessage = error
            return
        }
        notify(.success)
        dismiss()
    }

    @MainActor
    private func importPairingPhoto(_ item: PhotosPickerItem) async {
        errorMessage = ""
        isProcessing = true
        defer { isProcessing = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notify(.error)
            errorMessage = "Couldn't read that photo."
            return
        }

        do {
            let payload = try PairingQRCodeImageDecoder.decodePayload(from: data)
            handleScannedPayload(payload)
        } catch {
            notify(.error)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func scanClipboard() async {
        errorMessage = ""
        isProcessing = true
        defer { isProcessing = false }

        let clipboardString = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefersClipboardString = clipboardString.map(containsLikelyPairingLink(in:)) ?? false

        if prefersClipboardString, let clipboardString, !clipboardString.isEmpty {
            handleScannedPayload(clipboardString)
            return
        }

        if let image = UIPasteboard.general.image, let data = image.pngData() {
            do {
                let payload = try PairingQRCodeImageDecoder.decodePayload(from: data)
                handleScannedPayload(payload)
                return
            } catch {
                if let clipboardString, !clipboardString.isEmpty {
                    handleScannedPayload(clipboardString)
                    return
                }
            }
        }

        if let clipboardString, !clipboardString.isEmpty {
            handleScannedPayload(clipboardString)
            return
        }

        notify(.error)
        errorMessage = "Clipboard does not contain a pairing link or QR image."
    }

    private func containsLikelyPairingLink(in value: String) -> Bool {
        let normalized = value.lowercased()
        return MOBaiLEURLSchemeConfiguration.acceptedSchemes.contains { scheme in
            normalized.contains("\(scheme.lowercased())://pair")
        }
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

private struct PairingCameraPreview: UIViewRepresentable {
    @Binding var cameraState: PairingScannerCameraState
    let onCodeScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState, onCodeScanned: onCodeScanned)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.attach(to: view)
        context.coordinator.startScanning()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stopScanning()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let cameraState: Binding<PairingScannerCameraState>
        private let onCodeScanned: (String) -> Void
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "mobaile.pairing-scanner")
        private weak var previewView: PreviewView?
        private var isConfigured = false
        private var hasDeliveredCode = false

        init(cameraState: Binding<PairingScannerCameraState>, onCodeScanned: @escaping (String) -> Void) {
            self.cameraState = cameraState
            self.onCodeScanned = onCodeScanned
        }

        func attach(to view: PreviewView) {
            previewView = view
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
        }

        func startScanning() {
            guard hasCameraHardware else {
                cameraState.wrappedValue = .unavailable("Camera is not available on this device.")
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndStartSessionIfNeeded()
            case .notDetermined:
                cameraState.wrappedValue = .checkingPermission
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.configureAndStartSessionIfNeeded()
                        } else {
                            self.cameraState.wrappedValue = .denied
                        }
                    }
                }
            case .denied, .restricted:
                cameraState.wrappedValue = .denied
            @unknown default:
                cameraState.wrappedValue = .unavailable("Camera is not available.")
            }
        }

        func stopScanning() {
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        private func configureAndStartSessionIfNeeded() {
            sessionQueue.async {
                if !self.isConfigured {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video) else {
                        DispatchQueue.main.async {
                            self.cameraState.wrappedValue = .unavailable("Camera is not available on this device.")
                        }
                        return
                    }

                    do {
                        let input = try AVCaptureDeviceInput(device: camera)
                        self.session.beginConfiguration()
                        if self.session.canAddInput(input) {
                            self.session.addInput(input)
                        }

                        let output = AVCaptureMetadataOutput()
                        if self.session.canAddOutput(output) {
                            self.session.addOutput(output)
                            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                            output.metadataObjectTypes = [.qr]
                        }
                        self.session.commitConfiguration()
                        self.isConfigured = true
                    } catch {
                        DispatchQueue.main.async {
                            self.cameraState.wrappedValue = .unavailable("MOBaiLE could not start the camera.")
                        }
                        return
                    }
                }

                self.hasDeliveredCode = false
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.cameraState.wrappedValue = .ready
                }
            }
        }

        private var hasCameraHardware: Bool {
#if targetEnvironment(simulator)
            false
#else
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil ||
                AVCaptureDevice.default(for: .video) != nil
#endif
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasDeliveredCode else { return }
            guard let payload = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else {
                return
            }

            hasDeliveredCode = true
            stopScanning()
            onCodeScanned(payload)
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private struct PairingScannerOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.62

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.black.opacity(0.18))

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .frame(width: side, height: side)

                VStack {
                    Spacer()

                    Text("Center the QR inside the frame")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.44), in: Capsule())
                        .padding(.bottom, 18)
                }
            }
        }
    }
}
