// xcode: set sdk=iOS

//
//  LocationPickerView.swift
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

// MARK: - Location Picker View
struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var latitude: Double
    @Binding var longitude: Double
    @Binding var locationName: String
    
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedCoord: CLLocationCoordinate2D?
    
    @State private var searchQuery = ""
    @State private var searchResults: [MKMapItem] = []
    
    var body: some View {
        ZStack(alignment: .top) {
            MapReader { reader in
                Map(position: $position) {
                    if let selectedCoord { Annotation(locationName.isEmpty ? "Selected" : locationName, coordinate: selectedCoord) { Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red).background(Color.white, in: Circle()).shadow(radius: 3) } }
                    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) { UserAnnotation() }
                }
                .onTapGesture(coordinateSpace: .local) { tapPosition in
                    if let pinLocation = reader.convert(tapPosition, from: .local) {
                        selectedCoord = pinLocation; latitude = pinLocation.latitude; longitude = pinLocation.longitude
                        Task {
                            let geocoder = CLGeocoder()
                            let location = CLLocation(latitude: pinLocation.latitude, longitude: pinLocation.longitude)
                            if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                                locationName = placemark.name ?? placemark.thoroughfare ?? locationName
                            }
                        }
                    }
                }
            }
            
            // Search Bar & Results
            VStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search nearby...", text: $searchQuery)
                        .onSubmit { performSearch() }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchResults.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                
                if !searchResults.isEmpty {
                    List(searchResults, id: \.self) { item in
                        Button {
                            selectSearchResult(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Unknown").font(.headline).foregroundColor(.primary)
                                Text(item.placemark.title ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .listRowBackground(Color(uiColor: .systemBackground).opacity(0.9))
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 250)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .shadow(radius: 5)
                }
            }
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        if let loc = locationManager.location { withAnimation(.easeInOut) { position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else { locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut) { position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } }; locationManager.requestLocation() }
                    } label: { Image(systemName: "location.fill").font(.title3).padding().background(.regularMaterial).clipShape(Circle()).shadow(radius: 4) }.padding()
                }
            }
            
            VStack { Spacer(); Text("Tap anywhere to manually drop a pin").font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).padding(.bottom, 24) }
        }
        .navigationTitle("Select Location").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            if latitude != 0 && longitude != 0 {
                let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                selectedCoord = coord
                position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000))
            } else if !locationName.isEmpty {
                searchQuery = locationName
                locationManager.onLocationUpdate = { loc in
                    if selectedCoord == nil {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = locationName
                        request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
                        MKLocalSearch(request: request).start { response, _ in
                            if let first = response?.mapItems.first {
                                selectSearchResult(first)
                            }
                        }
                    }
                }
                locationManager.requestLocation()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if selectedCoord == nil {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = locationName
                        MKLocalSearch(request: request).start { response, _ in
                            if let first = response?.mapItems.first {
                                selectSearchResult(first)
                            }
                        }
                    }
                }
            } else {
                locationManager.onLocationUpdate = { loc in
                    if latitude == 0 && longitude == 0 {
                        position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
                    }
                }
                locationManager.requestLocation()
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        if let loc = locationManager.location {
            request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        }
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            guard let response = response else { return }
            searchResults = response.mapItems
        }
    }
    
    private func selectSearchResult(_ item: MKMapItem) {
        searchQuery = ""
        searchResults.removeAll()
        
        let coord = item.placemark.coordinate
        selectedCoord = coord
        latitude = coord.latitude
        longitude = coord.longitude
        locationName = item.name ?? item.placemark.title ?? item.placemark.name ?? ""
        
        withAnimation {
            position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500))
        }
    }
}


