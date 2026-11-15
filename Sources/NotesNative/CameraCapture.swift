@preconcurrency import AVFoundation
import Foundation
import NotesCore

public struct CameraDeviceInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var continuityCamera: Bool
    public var connected: Bool
    public var suspended: Bool

    public init(id: String, name: String, kind: String, continuityCamera: Bool,
                connected: Bool, suspended: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.continuityCamera = continuityCamera
        self.connected = connected
        self.suspended = suspended
    }
}

public struct CameraCaptureRequest: Sendable, Equatable {
    public static let maximumCount = 100

    public var device: String?
    public var delay: TimeInterval
    public var count: Int

    public init(device: String? = nil, delay: TimeInterval = 0, count: Int = 1) throws {
        guard delay.isFinite, (0...300).contains(delay) else {
            throw NotesError("invalid_camera_delay", "Camera delay must be between 0 and 300 seconds.")
        }
        guard (1...Self.maximumCount).contains(count) else {
            throw NotesError("invalid_camera_count", "Camera count must be between 1 and \(Self.maximumCount).")
        }
        self.device = device
        self.delay = delay
        self.count = count
    }
}

public protocol CameraImageSource: Sendable {
    func devices() -> [CameraDeviceInfo]
    func capture(_ request: CameraCaptureRequest) throws -> [FrozenAttachmentInput]
}

public struct InjectedCameraImageSource: CameraImageSource {
    private let image: FrozenAttachmentInput

    public init(file: URL) throws {
        image = try FrozenAttachmentInput(file: file)
        _ = try ScanCorrection.validateImageData(try Data(contentsOf: image.url), requireUpOrientation: false)
    }

    public init(data: Data, name: String = "injected-camera.png") throws {
        image = try FrozenAttachmentInput(data: data, suggestedName: name)
        _ = try ScanCorrection.validateImageData(data, requireUpOrientation: false)
    }

    public func devices() -> [CameraDeviceInfo] { [] }

    public func capture(_ request: CameraCaptureRequest) throws -> [FrozenAttachmentInput] {
        try (0..<request.count).map { index in
            let data = try Data(contentsOf: image.url, options: .mappedIfSafe)
            let stem = URL(fileURLWithPath: image.sourceName).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: image.sourceName).pathExtension
            let suffix = request.count == 1 ? "" : "-\(index + 1)"
            return try FrozenAttachmentInput(data: data, suggestedName: stem + suffix + (ext.isEmpty ? "" : "." + ext))
        }
    }
}

public final class AVCaptureCameraImageSource: NSObject, CameraImageSource, @unchecked Sendable {
    public override init() {}

    public func devices() -> [CameraDeviceInfo] {
        Self.captureDevices().map {
            CameraDeviceInfo(id: $0.uniqueID, name: $0.localizedName,
                             kind: $0.deviceType.rawValue,
                             continuityCamera: $0.isContinuityCamera,
                             connected: $0.isConnected, suspended: $0.isSuspended)
        }
    }

    public func capture(_ request: CameraCaptureRequest) throws -> [FrozenAttachmentInput] {
        try Self.requireAccess()
        let available = Self.captureDevices().filter(\.isConnected)
        let device: AVCaptureDevice
        if let selection = request.device {
            let exact = available.filter { $0.uniqueID == selection || $0.localizedName == selection }
            guard exact.count == 1, let selected = exact.first else {
                throw NotesError("camera_device_not_found", exact.isEmpty
                    ? "No connected camera matches '\(selection)'."
                    : "More than one connected camera matches '\(selection)'; use the device ID.",
                    hint: "Run 'notescli camera devices' and pass an ID with --device.")
            }
            device = selected
        } else {
            guard let selected = available.first else {
                throw NotesError("camera_device_not_found", "No connected AVCapture camera is available.",
                                 hint: "Connect a built-in, external, or Continuity Camera webcam, then run 'notescli camera devices'.")
            }
            device = selected
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw NotesError("camera_open_failed", "Could not open camera '\(device.localizedName)': \(error.localizedDescription)") }
        guard session.canAddInput(input) else {
            throw NotesError("camera_open_failed", "Camera '\(device.localizedName)' cannot be added to a photo session.")
        }
        let output = AVCapturePhotoOutput()
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw NotesError("camera_open_failed", "A photo output cannot be added for camera '\(device.localizedName)'.")
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }
        guard session.isRunning else {
            throw NotesError("camera_open_failed", "Camera '\(device.localizedName)' did not start.")
        }

        var images: [FrozenAttachmentInput] = []
        images.reserveCapacity(request.count)
        for index in 0..<request.count {
            if request.delay > 0 { Thread.sleep(forTimeInterval: request.delay) }
            let receiver = PhotoReceiver()
            let settings: AVCapturePhotoSettings
            if output.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else { settings = AVCapturePhotoSettings() }
            output.capturePhoto(with: settings, delegate: receiver)
            let data = try receiver.wait(timeout: 30)
            _ = try ScanCorrection.validateImageData(data, requireUpOrientation: false)
            images.append(try FrozenAttachmentInput(
                data: data,
                suggestedName: String(format: "camera-%03d.jpg", index + 1)
            ))
        }
        return images
    }

    public static func requestAccessForPermissions() throws {
        try requireAccess()
    }

    public static var accessStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        var seen = Set<String>()
        return session.devices.filter { seen.insert($0.uniqueID).inserted }
    }

    private static func requireAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .denied, .restricted:
            throw accessDenied()
        case .notDetermined:
            if ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil ||
                ProcessInfo.processInfo.environment["SSH_TTY"] != nil {
                throw accessDenied("Camera permission has not been granted, and an SSH session cannot show the macOS prompt.")
            }
            let semaphore = DispatchSemaphore(value: 0)
            let granted = LockedFlag()
            AVCaptureDevice.requestAccess(for: .video) { value in
                granted.value = value
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 30) == .success, granted.value else {
                throw accessDenied("Camera permission was not granted.")
            }
        @unknown default:
            throw accessDenied()
        }
    }

    private static func accessDenied(_ message: String = "Camera access is denied for NotesCLI Capability Host.") -> NotesError {
        NotesError("camera_access_denied", message,
                   hint: "Run 'notescli onboard' locally, then allow Camera for NotesCLI Capability Host in System Settings > Privacy & Security > Camera.")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class PhotoReceiver: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.withLock {
            if let error { result = .failure(error) }
            else if let data = photo.fileDataRepresentation() { result = .success(data) }
            else { result = .failure(NotesError("camera_capture_failed", "The camera returned no photo data.")) }
        }
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Data {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw NotesError("camera_capture_timeout", "The camera did not return a photo within \(Int(timeout)) seconds.")
        }
        return try lock.withLock {
            guard let result else { throw NotesError("camera_capture_failed", "The camera returned no result.") }
            do { return try result.get() }
            catch let error as NotesError { throw error }
            catch { throw NotesError("camera_capture_failed", "Photo capture failed: \(error.localizedDescription)") }
        }
    }
}
