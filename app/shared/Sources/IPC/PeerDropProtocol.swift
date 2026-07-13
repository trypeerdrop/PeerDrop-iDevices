//
//  layer.swift
//  PeerDrop
//
//  Created by joker on 2026-06-03.
//


//  PeerDropProtocol.swift
//  PeerDrop — Swift IPC protocol layer (mirror of protocol.js).
//
//  Owns command IDs, (de)serialization, and request/event routing. Plugs into
//  the EXISTING IPCBridge via its `setHandler` / `event` / `request` API — it
//  does not replace the transport, it sits on top of it.
//
//  SOLID:
//   - Single Responsibility: framing + routing only. No UI, no swarm, no models.
//   - Open/Closed: add a Command case + one method; nothing else changes.
//   - Interface Segregation: PeerDropEvents (inbound) is separate from the
//     outbound request methods, so the Worker only implements what it consumes.
//   - Dependency Inversion: Worker depends on PeerDropProtocol's typed surface,
//     not on bare-rpc, command integers, or JSON dictionaries.

import Foundation
import BareRPC

// MARK: - Inbound event sink

/// The application layer (Worker) conforms to this to receive decoded events.
/// Payloads arrive as already-decoded dictionaries; the Worker maps them to its
/// own models. (Dictionary-based to avoid a codegen step — can move to typed
/// structs later via the hyperschema/hrpc path on a branch.)
protocol PeerDropEvents: AnyObject {
    func onReady(_ payload: [String: Any])
    func onPeerConnected(_ payload: [String: Any])
    func onPeerDisconnected(_ payload: [String: Any])
    func onTransferStarted(_ payload: [String: Any])
    func onTransferProgress(_ payload: [String: Any])
    func onTransferComplete(_ payload: [String: Any])
    func onError(_ payload: [String: Any])
    func onSavedPeers(_ payload: [String: Any])
}

// MARK: - Protocol layer

/// Sits on top of IPCBridge. Construct it with the bridge and the event sink;
/// it registers itself as the bridge's external RPC handler and exposes typed
/// outbound methods.
final class PeerDropProtocol: RPCDelegate {

    enum Command: UInt {
        // JS → Swift events
        case ready             = 1
        case peerConnected     = 2
        case peerDisconnected  = 3
        case transferStarted   = 4
        case transferProgress  = 5
        case transferComplete  = 6
        case error             = 7
        case savedPeers        = 11
        // Swift → JS requests
        case sendFile          = 8
        case connectPeer       = 9
        case setDownloadPath   = 10
        case forgetPeer        = 12
        case setDeviceName     = 13
    }

    private let bridge: IPCBridge
    private weak var events: PeerDropEvents?

    init(bridge: IPCBridge, events: PeerDropEvents) {
        self.bridge = bridge
        self.events = events
        bridge.setHandler(self)   // route inbound through this layer
    }

    // ── Outbound: Swift → JS (typed) ──────────────────────────────────────────

    func connectPeer(peerID: String) {
        send(.connectPeer, ["peerID": peerID])
    }

    func sendFile(path: String, peerID: String) {
        send(.sendFile, ["filePath": path, "peerId": peerID])
    }

    func setDownloadPath(_ path: String) {
        send(.setDownloadPath, ["downloadPath": path])
    }

    func forgetPeer(discoveryKey: String) {
        send(.forgetPeer, ["peerDiscoveryKey": discoveryKey])
    }

    func setDeviceName(_ name: String) {
        send(.setDeviceName, ["deviceName": name])
    }

    // ── Outbound framing (single path through the bridge) ─────────────────────

    private func send(_ command: Command, _ body: [String: Any]) {
        Task {
            do { _ = try await bridge.request(command.rawValue, body: body) }
            catch { print("❌ [protocol] \(command) failed: \(error)") }
        }
    }

    // ── Inbound routing (RPCDelegate, called by IPCBridge._Delegate) ──────────

    func rpc(_ rpc: RPC, send data: Data) {}   // bridge owns the actual write

    func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
        request.reply(nil)                       // JS uses events; ack stray requests
    }

    func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async {
        guard
            let cmd  = Command(rawValue: event.command),
            let data = event.data,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        await MainActor.run {
            switch cmd {
            case .ready:            self.events?.onReady(json)
            case .peerConnected:    self.events?.onPeerConnected(json)
            case .peerDisconnected: self.events?.onPeerDisconnected(json)
            case .transferStarted:  self.events?.onTransferStarted(json)
            case .transferProgress: self.events?.onTransferProgress(json)
            case .transferComplete: self.events?.onTransferComplete(json)
            case .error:            self.events?.onError(json)
            case .savedPeers:       self.events?.onSavedPeers(json)
            default:                break   // request-only commands not received here
            }
        }
    }

    func rpc(_ rpc: RPC, didFailWith error: Error) {
        print("❌ [protocol] RPC error: \(error)")
    }
}