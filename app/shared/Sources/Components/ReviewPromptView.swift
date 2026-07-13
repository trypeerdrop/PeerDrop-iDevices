//
//  ReviewPromptView.swift
//

import SwiftUI
import StoreKit

#if os(iOS)
import UIKit
#endif

struct ReviewPromptView: View {
    @Environment(\.dismiss) private var dismiss

    /// Provided on macOS, where this view is hosted in a standalone NSWindow
    /// rather than presented as a sheet — @Environment(\.dismiss) has nothing
    /// to dismiss there, so this closure closes the window instead.
    var onDismiss: (() -> Void)? = nil

    @State private var animate = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            Image("PeerDrop") // Add this image to your Assets.xcassets
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .scaleEffect(animate ? 1 : 0.85)

            VStack(spacing: 10) {
                Text("Enjoying PeerDrop?")
                    .font(.title2.bold())

                Text("If PeerDrop has made sharing files easier, we'd really appreciate an App Store rating. It helps more people discover the app and supports future updates.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: "star.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .scaleEffect(animate ? 1 : 0)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.7)
                                .delay(Double(index) * 0.08),
                            value: animate
                        )
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    requestReview()
                } label: {
                    Label("Rate on App Store", systemImage: "star.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    close()
                } label: {
                    Text("Maybe Later")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(minWidth: 340, idealWidth: 360)
        .frame(height: 430)
        .scaleEffect(animate ? 1 : 0.95)
        .opacity(animate ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: animate)
        .onAppear {
            animate = true
        }
    }

    private func requestReview() {
        UserDefaults.standard.set(true, forKey: "hasPromptedForReview")

        #if os(iOS)
        // UIApplication.shared is unavailable when this file is compiled into
        // an app extension target (e.g. the Share Extension, which also builds
        // app/shared/). APP_EXTENSION is a custom flag set only on the
        // Share Extension target's build settings (see ios-share.yml) — Xcode
        // does not define one automatically. Skip the review prompt there;
        // it should only ever fire from the main app anyway.
        #if !APP_EXTENSION
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
        #endif
        #elseif os(macOS)
        SKStoreReviewController.requestReview()
        #endif

        close()
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }
}

#Preview {
    ReviewPromptView()
}
