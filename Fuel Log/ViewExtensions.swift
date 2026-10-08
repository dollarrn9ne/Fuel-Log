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
    ///
    /// - Parameter duoLeadingWidth: Duo's side panel only (`nil` everywhere
    ///   else, including real iPad - unaffected). Docks the sheet to the
    ///   leading edge and caps its width at this value, in both fully-open
    ///   and book-mode poses - the app's own side panel always occupies the
    ///   trailing half (against the hinge in book mode), so the data-entry
    ///   sheet takes the other, leading half instead of covering it or
    ///   spilling across the hinge. Requested directly: data-input sheets
    ///   should occupy a definite side of the screen on Duo, not float
    ///   centered over the map the way they do on a real iPad.
    func roomySheetOnPad(duoLeadingWidth: CGFloat? = nil) -> some View {
        presentationSizing(.page.fitted(horizontal: duoLeadingWidth != nil, vertical: false))
            .modifier(DuoSheetPlacement(leadingWidth: duoLeadingWidth))
    }
}

/// Bridges `View.presentationPlacement(_:)` (iOS 27.0+) the same way
/// `HingeTracker` bridges `onHingeChange` - callers pass a plain
/// `CGFloat?` instead of needing the real `PresentationPlacement` type,
/// which isn't available pre-27.0 (this app's deployment target is 26.2).
/// A no-op on older OSes and when `leadingWidth` is `nil`: the sheet keeps
/// its default, centred placement and `.page`'s own width.
///
/// The explicit `.frame(width:)` is what actually caps the presentation's
/// width - `.presentationSizing(.fitted)` only proposes `nil` so the
/// content's own frame decides the size, per Apple's own documented
/// pattern for fixed-size sheets. `.page`'s default horizontal sizing
/// otherwise sizes well past this fixed-width content, which bled across
/// the hinge/panel boundary on-device.
private struct DuoSheetPlacement: ViewModifier {
    let leadingWidth: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), let leadingWidth {
            content
                .frame(width: leadingWidth)
                .presentationPlacement(.leading)
        } else {
            content
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

