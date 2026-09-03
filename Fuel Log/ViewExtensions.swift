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

extension View {
    /// Caps a centred column of content so it doesn't stretch the full width of a
    /// roomy window. Buttons spanning ~1900pt on an iPad read as a phone layout
    /// blown up, and a capsule that wide stops looking like a button at all.
    ///
    /// Harmless on iPhone, where the window is narrower than the cap anyway.
    ///
    /// Caps, then expands again. The second frame matters: capping alone made the
    /// parent shrink to its widest child, since the full-width button was the only
    /// thing keeping it greedy - which left the background as a narrow column with
    /// bare window either side. Expanding after the cap keeps the container
    /// full-width and centres the capped content inside it.
    func centredContentColumn(maxWidth: CGFloat = 460) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Sheets default to a small form size on iPad, which crops a long form part
    /// way down and leaves it looking cramped and boxed in. Page sizing gives it
    /// room to breathe.
    ///
    /// No effect on iPhone, where a sheet fills the width regardless.
    func roomySheetOnPad() -> some View {
        presentationSizing(.page)
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

