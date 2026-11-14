import ScreenCaptureKit
import AppKit

@MainActor
final class SharingPicker: NSObject, SCContentSharingPickerObserver {
    var onSelection: ((SCContentFilter) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?
    override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }
    func present() {
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = .singleWindow
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.webinarnihongo.app"]
        config.allowsChangingSelectedContent = false
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = config
        picker.maximumStreamCount = 1
        picker.isActive = true
        picker.present(using: .window)
    }
    func deactivate() { SCContentSharingPicker.shared.isActive = false }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.onCancel?() }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.onSelection?(filter) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.onError?(error.localizedDescription) }
    }
}
