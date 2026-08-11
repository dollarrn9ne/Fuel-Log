// xcode: set sdk=iOS

//
//  ReusableComponents.swift
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

// MARK: - Reusable UI Components
struct FormTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboardType)
        }
    }
}

struct LocationField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onMapTap: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
            Button(action: onMapTap) {
                Image(systemName: "map.fill").foregroundColor(.accentColor)
            }
        }
    }
}

struct ProgressOverlay: View {
    let title: String
    let progress: Double
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(title).font(.headline)
                ProgressView(value: progress, total: 1.0).progressViewStyle(.linear)
                Text("\(Int(progress * 100))%").font(.subheadline)
            }
            .padding(24)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(16)
            .padding(40)
        }
    }
}

struct SuccessOverlay: View {
    let title: String
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.green)
                Text(title).font(.headline)
            }
            .padding(32)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(16)
            .shadow(radius: 10)
        }
    }
}

struct SelectedEventCard: View {
    let event: VehicleEvent
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: event.icon).foregroundStyle(event.color)
                Text(event.title).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(.secondary)
            }
            HStack {
                Text(event.date, style: .date)
                Spacer()
                Text(event.cost, format: .currency(code: event.vehicle?.currencyRaw ?? "USD")).fontWeight(.bold)
            }
            .font(.body).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}


