// xcode: set sdk=iOS

//
//  SplashScreenView.swift
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

// MARK: - App Logo
struct AppLogoIcon: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Splash Screen
struct SplashScreenView: View {
    @Binding var hasSeenSplash: Bool
    @State private var currentStep = 0
    @StateObject private var locationManager = CurrentLocationManager()

    var body: some View {
        ZStack {
            if currentStep == 0 {
                welcomeView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                locationView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: currentStep)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
    
    private var welcomeView: some View {
        VStack {
            Spacer()
            AppLogoIcon()
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 8)
                .padding(.bottom, 24)
            Text("Welcome to\nFuel Log")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)
            VStack(alignment: .leading, spacing: 32) {
                FeatureRow(icon: "fuelpump.fill", color: .blue, title: "Track Fuel & Efficiency", description: "Easily log your fill-ups and monitor your vehicle's fuel efficiency over time.")
                FeatureRow(icon: "wrench.and.screwdriver.fill", color: .orange, title: "Maintenance Logs", description: "Keep a detailed history of services.")
                FeatureRow(icon: "map.fill", color: .green, title: "Trip Tracking", description: "Record trips, categorize them, and calculate expected costs on the go.")
            }.padding(.horizontal, 32)
            Spacer()
            Button {
                currentStep = 1
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
    
    private var locationView: some View {
        VStack {
            Spacer()
            Image(systemName: "location.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(.blue, Color.blue.opacity(0.2))
                .shadow(color: .blue.opacity(0.3), radius: 15, x: 0, y: 8)
                .padding(.bottom, 24)
            Text("Location Services")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)
            VStack(alignment: .leading, spacing: 32) {
                FeatureRow(icon: "mappin.and.ellipse", color: .blue, title: "Nearby Stations", description: "Find nearby gas and service centers to easily log fill-ups and maintenance.")
                FeatureRow(icon: "clock.arrow.circlepath", color: .orange, title: "Locate Previous Data", description: "Automatically remember and auto-fill previous locations when logging.")
                FeatureRow(icon: "map.fill", color: .green, title: "Trip Tracking", description: "Effortlessly track your starting and ending coordinates for road trips.")
            }.padding(.horizontal, 32)
            Spacer()
            Button {
                locationManager.requestLocation()
                hasSeenSplash = true
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 36)).foregroundColor(color).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline.weight(.bold)); Text(description).font(.subheadline).foregroundColor(.secondary) }
        }
    }
}

