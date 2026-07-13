// App.swift — macOS @main entry point

import SwiftUI
import AppKit

@main
struct App: SwiftUI.App {

    @StateObject private var worker = Worker()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        MenuBarExtra("PeerDrop", systemImage: "drop.fill") {
            ContentView()
                .frame(height: 300)
                .environmentObject(worker)
                .onAppear {
                    if !hasCompletedOnboarding {
                        openOnboardingWindow()
                    }
                }
                .onChange(of: worker.showReviewPrompt) { show in
                    // Menu bar popovers can't host a .sheet reliably (size-constrained,
                    // dismisses unexpectedly) — same reason onboarding uses a standalone
                    // NSWindow instead of a sheet. Do the same here.
                    guard show else { return }
                    openReviewPromptWindow()
                    worker.showReviewPrompt = false   // the window now owns presentation
                }
        }
        .menuBarExtraStyle(.window)
    }

    func openOnboardingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask:   [.titled, .closable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        window.title           = "Welcome to PeerDrop"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true

        var isPresented = true
        let binding = Binding<Bool>(
            get:  { isPresented },
            set:  { newVal in
                isPresented = newVal
                if !newVal {
                    hasCompletedOnboarding = true
                    window.close()
                }
            }
        )

        window.contentView = NSHostingView(
            rootView: OnboardingView(isPresented: binding)
                .environmentObject(worker)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shown once, after the first successful file transfer (see
    /// Worker+Events.onTransferComplete). Same standalone-window pattern as
    /// onboarding — a MenuBarExtra popover isn't a suitable sheet host.
    func openReviewPromptWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
            styleMask:   [.titled, .closable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        window.title                      = ""
        window.center()
        window.isReleasedWhenClosed       = false
        window.titlebarAppearsTransparent = true
        // Float above other windows — there's no Dock icon to click back to
        // since this is a menu-bar-only app, so keep it reachable.
        window.level = .floating

        window.contentView = NSHostingView(
            rootView: ReviewPromptView(onDismiss: { window.close() })
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
