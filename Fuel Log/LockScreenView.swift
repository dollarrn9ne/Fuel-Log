// xcode: set sdk=iOS

//
//  LockScreenView.swift
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

// MARK: - LocalAuthentication Extension
extension LAContext {
    var biometryName: String {
        var error: NSError?
        // Call canEvaluatePolicy first so that biometryType is populated
        _ = canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        
        if biometryType == .faceID {
            return "Face ID"
        } else if biometryType == .touchID {
            return "Touch ID"
        } else {
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
                if biometryType == .opticID {
                    return "Optic ID"
                }
            }
            return "Passcode"
        }
    }
}
// MARK: - Lock Screen View
struct LockScreenView: View {
    @Binding var isUnlocked: Bool
    @State private var unlockMethodName = "Biometrics"

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            
            VStack(spacing: 32) {
                AppLogoIcon()
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    
                    Text("App Locked")
                        .font(.title2.weight(.bold))
                }
                
                Button(action: authenticate) {
                    Text("Unlock with \(unlockMethodName)")
                        .font(.headline.weight(.bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 40)
                .padding(.top, 24)
            }
        }
        .onAppear {
            unlockMethodName = LAContext().biometryName
            authenticate()
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Fuel Log") { success, _ in
                DispatchQueue.main.async {
                    if success {
                        isUnlocked = true
                    }
                }
            }
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // Fallback to passcode if biometrics are disabled but passcode is set
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Fuel Log") { success, _ in
                DispatchQueue.main.async {
                    if success {
                        isUnlocked = true
                    }
                }
            }
        }
    }
}


