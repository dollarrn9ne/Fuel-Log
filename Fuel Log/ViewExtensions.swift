// xcode: set sdk=iOS

//
//  ViewExtensions.swift
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

extension View {
    @ViewBuilder
    func applyLiquidGlassOrBackground(cornerRadius: CGFloat, fallbackColor: UIColor = .secondarySystemGroupedBackground, useGlass: Bool = true) -> some View {
        // Liquid Glass applies a vibrancy foreground treatment to its content, so
        // it only stays legible over content with contrast beneath it (e.g. a map
        // or a sheet material). On flat backgrounds the text washes out, so callers
        // there pass `useGlass: false` to get the solid card instead.
        if #available(iOS 26.0, *), useGlass {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(Color(uiColor: fallbackColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension Double {
    var odometerString: String {
        if self == self.rounded() {
            return String(Int(self))
        }
        return String(self)
    }
}

