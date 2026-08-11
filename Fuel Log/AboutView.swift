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
    
    var body: some View {
        List {
            VStack(spacing: 16) {
                AppLogoIcon()
                    .frame(width: 100, height: 100)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    .padding(.top, 24)
                
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
                    
                    Text("@Motosung, 2026")
                        .foregroundStyle(.secondary)
                    
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 16)
            
            Section {
                Button(action: {
                    if let url = URL(string: "mailto:imotosung@icloud.com") {
                        openURL(url)
                    }
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Email Developer")
                            .foregroundStyle(.primary)
                    }
                }
                
                Button(action: {
                    #if targetEnvironment(simulator)
                    showingSimulatorReviewNote = true
                    #else
                    requestReview()
                    #endif
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Rate and Review")
                            .foregroundStyle(.primary)
                    }
                }
                
                Button(action: {
                    if let url = URL(string: "https://t.me/+OaIw90MuUt9iYmI5") {
                        openURL(url)
                    }
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Telegram Updates")
                            .foregroundStyle(.primary)
                    }
                }
                
                Button {
                    Task { await storeKit.purchase() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(storeKit.hasPurchasedSupport ? .pink : .blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        VStack(alignment: .leading) {
                            Text(storeKit.hasPurchasedSupport ? "Thank You for Your Support!" : "Support Developer")
                                .foregroundStyle(.primary)
                            if storeKit.hasPurchasedSupport {
                                Text("You've already supported development")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        if storeKit.isPurchasing {
                            ProgressView()
                        }
                    }
                }
                .disabled(storeKit.hasPurchasedSupport || storeKit.isPurchasing)
                
                Button {
                    Task { await storeKit.restorePurchases() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Restore Purchases")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
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
}


