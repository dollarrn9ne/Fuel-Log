// xcode: set sdk=iOS

//
//  ScannerAndDocuments.swift
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

// MARK: - Receipt Scanning & Parsing (100% On-Device)
struct DocumentScanner: UIViewControllerRepresentable {
    @Binding var scannedImage: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    @MainActor
    class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        var parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if scan.pageCount > 0 {
                parent.scannedImage = scan.imageOfPage(at: 0)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - CSV Document
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    var encoding: String.Encoding
    
    init(text: String, encoding: String.Encoding = .utf8) {
        self.text = text
        self.encoding = encoding
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else { text = "" }
        self.encoding = .utf8
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: encoding) ?? text.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

