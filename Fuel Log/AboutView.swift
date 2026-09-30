// xcode: set sdk=iOS

//
//  AboutView.swift
//  Fuel Log
//
//  Created by Denis Yeremuk on 3/12/26.
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation
import MapKit
import PhotosUI
import StoreKit
import UniformTypeIdentifiers
import Combine
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications
@preconcurrency import Vision
import VisionKit
import AppIntents
import LocalAuthentication
import FuelLogShared

// MARK: - About View
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @StateObject private var storeKit = StoreKitManager()
    @State private var showingSimulatorReviewNote = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Version \(version)"
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(get: { storeKit.errorMessage != nil }, set: { if !$0 { storeKit.errorMessage = nil } })
    }

    // A plain VStack rather than a List: a List is always a scroll view, and
    // this page's content is short enough to lay out statically on one
    // screen (including Duo's shorter outer display) without needing one.
    // The 4 action rows are grouped into a single card instead of a List
    // Section, so there's one section, not several.
    var body: some View {
        VStack(spacing: 16) {
            AppLogoIcon()
                .frame(width: 90, height: 90)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)

            Text("Fuel Log")
                .font(.title2.weight(.bold))

            VStack(spacing: 6) {
                Text("Jeremiah 29:11")
                    .foregroundStyle(.secondary)

                Text("Made in California, by a Ukrainian")
                    .foregroundStyle(.secondary)

                Text("No Subscription, Ever.")
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
            }
            .font(.subheadline)

            VStack(spacing: 0) {
                aboutRow(systemImage: "envelope.fill", title: "Email Developer") {
                    if let url = URL(string: "mailto:imotosung@icloud.com") { openURL(url) }
                }
                Divider().padding(.leading, 56)

                aboutRow(systemImage: "star.fill", title: "Rate and Review") {
                    #if targetEnvironment(simulator)
                    showingSimulatorReviewNote = true
                    #else
                    requestReview()
                    #endif
                }
                Divider().padding(.leading, 56)

                aboutRow(systemImage: "paperplane.fill", title: "Telegram Updates") {
                    if let url = URL(string: "https://t.me/+OaIw90MuUt9iYmI5") { openURL(url) }
                }
                Divider().padding(.leading, 56)

                Menu {
                    ForEach(SupportTier.allCases) { tier in
                        Button(storeKit.displayPrice(for: tier)) {
                            Task { await storeKit.purchase(tier) }
                        }
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(storeKit.hasPurchasedSupport ? .pink : .blue)
                            .font(.title3)
                            .frame(width: 24)

                        VStack(alignment: .leading) {
                            Text("Support Developer")
                                .foregroundStyle(.primary)
                            Text(storeKit.hasPurchasedSupport
                                 ? "Thank you for your support!"
                                 : "Choose an amount to tip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if storeKit.isPurchasing {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .disabled(storeKit.isPurchasing)
            }
            .applyLiquidGlassOrBackground(cornerRadius: 14, fallbackColor: .secondarySystemGroupedBackground)

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Text("@Motosung, 2026")
                Text(appVersion)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("About Fuel Log")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Thank you for your support!", isPresented: $storeKit.purchaseCompleted) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Thank you for your support. Without you, this wouldn't be possible.")
        }
        .alert("Support Developer", isPresented: isErrorPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(storeKit.errorMessage ?? "")
        }
        .alert("Rating Is Only on Real Devices", isPresented: $showingSimulatorReviewNote) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The App Store rating prompt doesn't appear in the Simulator. Run Fuel Log on a real iPhone to rate and review.")
        }
    }

    @ViewBuilder
    private func aboutRow(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                    .font(.title3)
                    .frame(width: 24)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


