//  Worker.swift — application layer (UI-facing state).
//

import Foundation
#if canImport(AppKit)
import AppKit
import UserNotifications
#elseif canImport(UIKit)
import UIKit
#endif

class Worker: ObservableObject {

    // MARK: - Published state

    @Published var myPeerID:        String         = ""
    @Published var knownDevices:    [PeerDevice]   = []
    @Published var activeTransfers: [FileTransfer] = []
    @Published var downloadPath:    String         = ""
    @Published var showReviewPrompt: Bool         = false

    // MARK: - Computed sections

    var myDevices: [PeerDevice] { knownDevices.filter(\.isOwnDevice) }
    var contacts:  [PeerDevice] { knownDevices.filter { !$0.isOwnDevice } }

    // MARK: - Internal

    let bridge = IPCBridge()
    private(set) var proto: PeerDropProtocol!
    var noiseToDiscovery: [String: String] = [:]

    // MARK: - Init

    init() {
        // Build the protocol layer on top of the bridge, with self as the
        // event sink. This replaces the old setupEventHandlers() + RPCDelegate.
        proto = PeerDropProtocol(bridge: bridge, events: self)
        Task { await bridge.start() }
    }

    // MARK: - Public intent API (views call these)

    func sendFile(at url: URL, to discoveryKey: String) {
        proto.sendFile(path: url.path, peerID: discoveryKey)
    }

    func connectPeer(peerID: String) {
        proto.connectPeer(peerID: peerID)
    }

    func forgetPeer(discoveryKey: String) {
        proto.forgetPeer(discoveryKey: discoveryKey)
    }

    func setDownloadPath(_ path: String) {
        DispatchQueue.main.async { self.downloadPath = path }
        proto.setDownloadPath(path)
    }

    // MARK: - Pending transfer from Share Extension

    func processPendingTransfer() {
        guard let pending = AppGroup.readPendingTransfer() else { return }
        AppGroup.clearPendingTransfer()
        guard let url = URL(string: pending.fileURL) else { return }
        sendFile(at: url, to: pending.peerKey)
    }

    // MARK: - Helpers

    func systemImage(for platform: String) -> String {
        switch platform.lowercased() {
        case "darwin":           return "laptopcomputer"
        case "linux":            return "server.rack"
        case "win32", "windows": return "laptopcomputer"
        case "ios":              return "iphone"
        default:                 return "desktopcomputer"
        }
    }

    // MARK: - App Group sync

    func syncPeersToAppGroup() {
        let appGroupPeers = knownDevices.map { device in
            AppGroupPeer(
                discoveryKey: device.discoveryKey,
                displayName:  device.name,
                platform:     device.systemImage,
                isOnline:     device.isOnline,
                isOwnDevice:  device.isOwnDevice
            )
        }
        AppGroup.writePeers(appGroupPeers)
    }

    // MARK: - Notifications

    func showNotification(title: String, body: String) {
        #if canImport(AppKit)
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { if let e = $0 { print("❌ Notification: \(e)") } }
        #endif
    }

    // MARK: - Lifecycle

    func suspend()   { bridge.suspend() }
    func resume()    { bridge.resume() }
    func terminate() { bridge.terminate() }
}
