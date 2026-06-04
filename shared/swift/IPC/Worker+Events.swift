//  Worker+Events.swift — PeerDropEvents conformance (inbound → model updates).
//
//  The only place that knows how a decoded event payload maps onto the app's
//  models. No command IDs, no JSON framing, no RPCDelegate. Routing already
//  happens on the main actor (PeerDropProtocol dispatches there), so these
//  methods can touch @Published state directly.

import Foundation

extension Worker: PeerDropEvents {

    func onReady(_ payload: [String: Any]) {
        guard let peerID = payload["peerID"] as? String else { return }
        myPeerID     = peerID
        downloadPath = payload["downloadPath"] as? String ?? ""
        // Device name is delivered via Bare.argv[1] at startup (see IPCBridge),
        // so there's nothing to send back here anymore.
    }

    func onSavedPeers(_ payload: [String: Any]) {
        guard let peers = payload["peers"] as? [[String: Any]] else { return }
        knownDevices = peers.compactMap { p in
            guard let dk = p["discoveryKey"] as? String else { return nil }
            let name     = p["displayName"] as? String
            let platform = p["platform"]    as? String
            let isOnline = knownDevices.first(where: { $0.id == dk })?.isOnline ?? false
            return PeerDevice(
                id:           dk,
                discoveryKey: dk,
                name:         name ?? String(dk.prefix(12)) + "...",
                systemImage:  systemImage(for: platform ?? ""),
                isOnline:     isOnline,
                isOwnDevice:  dk == myPeerID
            )
        }
        syncPeersToAppGroup()
    }

    func onPeerConnected(_ payload: [String: Any]) {
        guard
            let noiseKey     = payload["noiseKey"]     as? String,
            let discoveryKey = payload["discoveryKey"] as? String,
            let displayName  = payload["displayName"]  as? String,
            let platform     = payload["platform"]     as? String
        else { return }
        let isOwnDevice = payload["isOwnDevice"] as? Bool ?? false

        noiseToDiscovery[noiseKey] = discoveryKey
        let updated = PeerDevice(
            id:           discoveryKey,
            discoveryKey: discoveryKey,
            name:         displayName,
            systemImage:  systemImage(for: platform),
            isOnline:     true,
            isOwnDevice:  isOwnDevice
        )
        if let i = knownDevices.firstIndex(where: { $0.id == discoveryKey }) {
            knownDevices[i] = updated
        } else {
            knownDevices.append(updated)
        }
        syncPeersToAppGroup()
    }

    func onPeerDisconnected(_ payload: [String: Any]) {
        guard let noiseKey = payload["noiseKey"] as? String else { return }
        guard let dk = noiseToDiscovery.removeValue(forKey: noiseKey) else { return }
        if let i = knownDevices.firstIndex(where: { $0.id == dk }) {
            let d = knownDevices[i]
            knownDevices[i] = PeerDevice(
                id:           d.id,
                discoveryKey: d.discoveryKey,
                name:         d.name,
                systemImage:  d.systemImage,
                isOnline:     false,
                isOwnDevice:  d.isOwnDevice
            )
        }
        syncPeersToAppGroup()
    }

    func onTransferStarted(_ payload: [String: Any]) {
        guard
            let id        = payload["transferId"] as? String,
            let peerId    = payload["peerId"]     as? String,
            let fileName  = payload["fileName"]   as? String,
            let fileSize  = payload["fileSize"]   as? Int,
            let direction = payload["direction"]  as? String
        else { return }
        activeTransfers.append(FileTransfer(
            id:          id,
            peerId:      peerId,
            fileName:    fileName,
            fileSize:    Int64(fileSize),
            progress:    0,
            direction:   direction == "receiving" ? .receiving : .sending,
            isDirectory: payload["isDirectory"] as? Bool ?? false,
            fileCount:   payload["fileCount"]   as? Int  ?? 0
        ))
    }

    func onTransferProgress(_ payload: [String: Any]) {
        guard
            let id       = payload["transferId"] as? String,
            let progress = payload["progress"]   as? Double
        else { return }
        if let i = activeTransfers.firstIndex(where: { $0.id == id }) {
            var t = activeTransfers[i]; t.progress = progress
            activeTransfers[i] = t
        }
    }

    func onTransferComplete(_ payload: [String: Any]) {
        guard let id = payload["transferId"] as? String else { return }
        if let t = activeTransfers.first(where: { $0.id == id }) {
            showNotification(
                title: t.direction == .receiving ? "File Received" : "File Sent",
                body:  t.direction == .receiving
                    ? "\(t.fileName) saved to downloads folder"
                    : "\(t.fileName) sent successfully"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.activeTransfers.removeAll { $0.id == id }
        }
    }

    func onError(_ payload: [String: Any]) {
        if let msg = payload["message"] as? String { print("❌ JS: \(msg)") }
    }
}
