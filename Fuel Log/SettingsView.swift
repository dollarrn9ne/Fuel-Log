import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LocalAuthentication
import FuelLogShared

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("lastSelectedVehicleID") private var lastSelectedVehicleID: String = ""
    @AppStorage("smartRemindersEnabled") private var smartRemindersEnabled: Bool = false
    @AppStorage("appLockEnabled") private var appLockEnabled: Bool = false
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled: Bool = true
    @Query private var vehicles: [Vehicle]
    @Query private var shareTokens: [ShareToken]
    @ObservedObject private var syncManager = SyncManager.shared
    
    @State private var selectedEncoding: ExportEncoding = .utf8
    @State private var showFileExporter = false
    @State private var showFileImporter = false
    @State private var showingImportSourcePicker = false
    @State private var showingExportVehiclePicker = false
    @State private var showingTaxReportSheet = false
    @State private var showingServiceReportSheet = false
    @State private var showingPurgeConfirmation = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importProgress: Double = 0.0
    @State private var exportProgress: Double = 0.0
    @State private var pendingImportSource: ImportSource = .none
    @State private var csvDocument: CSVDocument?
    @State private var exportFilename = "VehicleData"

    @State private var backupDocument: JSONDocument?
    @State private var showingBackupExporter = false
    @State private var showingRestoreImporter = false
    @State private var showingRestoreConfirmation = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var backupProgress: Double = 0.0
    @State private var restoreProgress: Double = 0.0
    @State private var showBackupSuccess = false
    @State private var showRestoreSuccess = false
    @State private var backupErrorMessage: String?
    @State private var showingBackupError = false
    
    @State private var showExportSuccess = false
    @State private var showImportSuccess = false
    @State private var showingBiometricError = false
    @State private var unlockMethodName = "Face ID / Touch ID"
    
    var body: some View {
        Form {
            Section("Appearance") { Picker("Theme", selection: $appTheme) { ForEach(AppTheme.allCases) { theme in Text(theme.rawValue).tag(theme) } } }
            Section(header: Text("Backup & Restore")) {
                HStack {
                    Image(systemName: syncManager.status.icon)
                        .foregroundStyle(syncManager.status.tintColor)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(syncManager.status.label).font(.headline)
                        Text(syncManager.status.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                
                if isCloudUsable {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text(lastSyncedText)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await syncNow() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Sync Now")
                                    if syncManager.status.isBusy {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .disabled(syncManager.status.isBusy)
                        }
                    } label: {
                        Text("Last Synced")
                    }
                }
                
                Button {
                    Task { await generateLocalBackup() }
                } label: {
                    Label("Local Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(isBackingUp || isRestoring)
                
                Button {
                    showingRestoreConfirmation = true
                } label: {
                    Label("Local Restore", systemImage: "square.and.arrow.down")
                }
                .disabled(isBackingUp || isRestoring)
            }
            
            Section(header: Text("Security")) {
                Toggle("Require \(unlockMethodName)", isOn: Binding(
                    get: { appLockEnabled },
                    set: { newValue in
                        if newValue {
                            let context = LAContext()
                            var error: NSError?
                            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Enable App Lock") { success, _ in
                                    DispatchQueue.main.async {
                                        if success {
                                            appLockEnabled = true
                                        }
                                    }
                                }
                            } else {
                                showingBiometricError = true
                            }
                        } else {
                            appLockEnabled = false
                        }
                    }
                ))
            }
            
            Section(header: Text("Smart Notifications")) {
                Toggle("Maintenance Reminders", isOn: $smartRemindersEnabled)
                    .onChange(of: smartRemindersEnabled) { _, isEnabled in
                        if isEnabled {
                            SmartRemindersManager.shared.requestPermission { granted in
                                Task { @MainActor in
                                    if granted {
                                        for v in vehicles {
                                            SmartRemindersManager.shared.updateReminders(for: v)
                                        }
                                    } else {
                                        smartRemindersEnabled = false
                                    }
                                }
                            }
                        } else {
                            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                        }
                    }
                if smartRemindersEnabled {
                    Text("We remind you when your next service is due; whichever comes first: distance (e.g., 5,000 mi) or time (e.g., 6 months). All predictions run privately, on-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Fill-Up Live Activity", isOn: $liveActivityEnabled)
                Text("While you enter a fill-up, the running total appears on the lock screen and Dynamic Island. Turn off to stop starting new Live Activities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Reports") {
                Text("Export a formatted report of trips, mileage, and expenses for tax purposes, or export your service records as proof of maintenance upkeep; ideal when selling the car.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button { showingTaxReportSheet = true } label: { Label("Export Tax Report", systemImage: "doc.text.fill") }
                
                Button { showingServiceReportSheet = true } label: { Label("Export Service Report", systemImage: "wrench.and.screwdriver.fill") }
            }
            
            Section("Import & Export") {
                Text("Import data from another app, or export your data to use in another app.").font(.caption).foregroundStyle(.secondary)
                Picker("CSV Text Encoding", selection: $selectedEncoding) { ForEach(ExportEncoding.allCases) { enc in Text(enc.rawValue).tag(enc) } }
                
                Button { showingExportVehiclePicker = true } label: { Label("Export Vehicle Data (CSV)", systemImage: "square.and.arrow.up") }
                .confirmationDialog("Select Vehicle to Export", isPresented: $showingExportVehiclePicker, titleVisibility: .visible) {
                    Button("All Vehicles") { Task { await generateCSV(for: nil) } }
                    ForEach(vehicles) { vehicle in Button("\(vehicle.name)\(vehicle.isArchived ? " (Archived)" : "")") { Task { await generateCSV(for: vehicle) } } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Choose which vehicle's logs to export, or export them all together.") }
                
                Button { showingImportSourcePicker = true } label: { Label("Import Vehicle Data (CSV)", systemImage: "square.and.arrow.down") }
                .confirmationDialog("Select Source App", isPresented: $showingImportSourcePicker, titleVisibility: .visible) {
                    ForEach(ImportSource.allCases) { source in Button(source.rawValue) { pendingImportSource = source; showFileImporter = true } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Select the app that generated your CSV so it can be formatted correctly.") }
            }
            
            if shareTokens.contains(where: { $0.isActive }) {
                Section("Sharing") {
                    NavigationLink { SharedLinksView() } label: {
                        Label("Shared Vehicles", systemImage: "person.2.fill")
                    }
                    Text("Vehicles you've shared so borrowers can log fuel for them. Revoke a link to stop importing its entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Danger Zone")) {
                Button(role: .destructive) { showingPurgeConfirmation = true } label: { Label("Erase All App Data", systemImage: "trash.fill") }
                .alert("Erase All App Data?", isPresented: $showingPurgeConfirmation) { Button("Cancel", role: .cancel) {}; Button("Erase Everything", role: .destructive) { purgeAllData() } } message: { Text("This will permanently delete all vehicles, trips, categories, and logs. This action cannot be undone.") }
            }
            
            Section { NavigationLink(destination: AboutView()) { Text("About Fuel Log") } }
        }
        .navigationTitle("Settings").toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary).font(.title3) } } }
        .fileExporter(isPresented: $showFileExporter, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: exportFilename) { result in
            if case .success = result {
                withAnimation { showExportSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showExportSuccess = false }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                if let data = try? String(contentsOf: url, encoding: selectedEncoding.stringEncoding) {
                    isImporting = true
                    importProgress = 0.0
                    Task {
                        await performImport(data: data, source: pendingImportSource)
                        isImporting = false
                        withAnimation { showImportSuccess = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation { showImportSuccess = false }
                        }
                    }
                }
                url.stopAccessingSecurityScopedResource()
            }
        }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .json, defaultFilename: defaultBackupFilename) { result in
            if case .success = result {
                withAnimation { showBackupSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showBackupSuccess = false }
                }
            }
        }
        .fileImporter(isPresented: $showingRestoreImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                if let data = try? Data(contentsOf: url) {
                    Task { await restoreFromBackup(data: data) }
                }
                url.stopAccessingSecurityScopedResource()
            }
        }
        .sheet(isPresented: $showingTaxReportSheet) {
            NavigationStack {
                TaxReportConfigView(vehicles: vehicles)
            }
        }
        .sheet(isPresented: $showingServiceReportSheet) {
            NavigationStack {
                ServiceReportConfigView(vehicles: vehicles)
            }
        }
        .alert("Biometrics Unavailable", isPresented: $showingBiometricError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your device does not support Face ID, Touch ID, or Passcode, or they are not configured.")
        }
        .alert("Restore Backup?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Choose Backup…", role: .destructive) { showingRestoreImporter = true }
        } message: {
            Text("Restoring will replace all current vehicles, trips, categories, and logs with the contents of the backup you select. This cannot be undone.")
        }
        .alert("Backup & Restore", isPresented: $showingBackupError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupErrorMessage ?? "Something went wrong.")
        }
        .overlay {
            if isImporting { ProgressOverlay(title: "Importing Data...", progress: importProgress) }
            else if isExporting { ProgressOverlay(title: "Generating CSV...", progress: exportProgress) }
            else if isBackingUp { ProgressOverlay(title: "Creating Backup...", progress: backupProgress) }
            else if isRestoring { ProgressOverlay(title: "Restoring Backup...", progress: restoreProgress) }
            else if showExportSuccess { SuccessOverlay(title: "Saved Successfully!") }
            else if showImportSuccess { SuccessOverlay(title: "Import Complete!") }
            else if showBackupSuccess { SuccessOverlay(title: "Backup Saved!") }
            else if showRestoreSuccess { SuccessOverlay(title: "Restore Complete!") }
        }
        .onAppear {
            unlockMethodName = LAContext().biometryName
        }
        .task {
            syncManager.loadPersistedLastSync()
            await syncManager.checkStatus()
        }
    }
    
    private var lastSyncedText: String {
        guard let date = syncManager.lastSuccessfulSync else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Whether iCloud is in a state where a "Last Synced / Sync Now" row makes
    /// sense. Hidden when the user isn't signed in / iCloud is unavailable, so we
    /// don't show a stale sync time alongside a "Not Signed In" status.
    private var isCloudUsable: Bool {
        switch syncManager.status {
        case .active, .syncing, .checking: return true
        case .notSignedIn, .restricted, .unavailable, .error: return false
        }
    }
    
    private func syncNow() async {
        await syncManager.forceSync()
    }
    
    private func purgeAllData() {
        do {
            try modelContext.delete(model: Vehicle.self)
            try modelContext.delete(model: Trip.self)
            try modelContext.delete(model: TripCategory.self)
            try modelContext.delete(model: GasLocation.self)
            try modelContext.save()
            lastSelectedVehicleID = ""
            dismiss()
        } catch { print("Failed to purge data: \(error)") }
    }
    
    @MainActor private func generateCSV(for targetVehicle: Vehicle?) async {
        isExporting = true; exportProgress = 0.0; exportFilename = targetVehicle != nil ? "\(targetVehicle!.name)_Logs" : "All_Vehicles_Logs"
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        var csvString = "Vehicle,Record Type,Date,Odometer,Cost,Details,Location,Notes\n"
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        let vehiclesToExport = targetVehicle == nil ? vehicles : [targetVehicle!]
        let totalEvents = vehiclesToExport.reduce(0) { $0 + ($1.fillUps ?? []).count + ($1.services ?? []).count }
        let totalDouble = Double(max(1, totalEvents)); var currentCount = 0.0
        
        for vehicle in vehiclesToExport {
            for f in (vehicle.fillUps ?? []) {
                csvString.append("\"\(vehicle.name)\",\"Fuel\",\"\(df.string(from: f.date))\",\"\(f.odometer?.odometerString ?? "")\",\"\(f.totalCost)\",\"\(f.volume) \(f.unit.rawValue)\",\"\(f.location?.name.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\",\"\(f.notes.replacingOccurrences(of: "\"", with: "\"\""))\"\n")
                currentCount += 1; if Int(currentCount) % 20 == 0 { exportProgress = currentCount / totalDouble; try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            for s in (vehicle.services ?? []) {
                csvString.append("\"\(vehicle.name)\",\"Service\",\"\(df.string(from: s.date))\",\"\(s.odometer.odometerString)\",\"\(s.cost)\",\"\(s.type.rawValue)\",\"\(s.location?.name.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\",\"\(s.notes.replacingOccurrences(of: "\"", with: "\"\""))\"\n")
                currentCount += 1; if Int(currentCount) % 20 == 0 { exportProgress = currentCount / totalDouble; try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        exportProgress = 1.0; try? await Task.sleep(nanoseconds: 200_000_000)
        csvDocument = CSVDocument(text: csvString, encoding: selectedEncoding.stringEncoding); isExporting = false; showFileExporter = true
    }
    
    @MainActor private func performImport(data: String, source: ImportSource) async {
        let importer = CSVImporter()
        await importer.performImport(data: data, source: source, modelContext: modelContext)
    }
    
    private var defaultBackupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "FuelLog_Backup_\(formatter.string(from: Date()))"
    }
    
    @MainActor private func generateLocalBackup() async {
        isBackingUp = true
        backupProgress = 0.0
        defer { isBackingUp = false }
        do {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let data = try FullBackup.exportData(context: modelContext)
            backupProgress = 1.0
            backupDocument = JSONDocument(data: data)
            showingBackupExporter = true
        } catch {
            backupErrorMessage = "Backup failed: \(error.localizedDescription)"
            showingBackupError = true
        }
    }
    
    @MainActor private func restoreFromBackup(data: Data) async {
        isRestoring = true
        restoreProgress = 0.0
        defer { isRestoring = false }
        do {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try FullBackup.restore(from: data, context: modelContext)
            restoreProgress = 1.0
            lastSelectedVehicleID = ""
            withAnimation { showRestoreSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation { showRestoreSuccess = false }
            }
        } catch {
            backupErrorMessage = "Restore failed: \(error.localizedDescription)"
            showingBackupError = true
        }
    }
}

// MARK: - Shared Vehicles Management

/// Lists the vehicles the user has shared for logging, and lets them re-share
/// the link or revoke it (which stops imports and removes its push subscription).
struct SharedLinksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ShareToken> { $0.isActive }, sort: \ShareToken.createdAt, order: .reverse)
    private var tokens: [ShareToken]
    @Query private var vehicles: [Vehicle]

    @State private var shareItem: VehicleShareItem?

    var body: some View {
        List {
            if tokens.isEmpty {
                ContentUnavailableView(
                    "No Shared Vehicles",
                    systemImage: "person.2.slash",
                    description: Text("Share a vehicle from its dashboard to let someone log fuel for it.")
                )
            } else {
                Section {
                    ForEach(tokens) { token in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(token.vehicleName.isEmpty ? "Vehicle" : token.vehicleName)
                                .font(.headline)
                            Text("Shared \(token.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { revoke(token) } label: {
                                Label("Revoke", systemImage: "xmark.circle")
                            }
                            Button { reshare(token) } label: {
                                Label("Link", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                } footer: {
                    Text("Revoking stops importing fill-ups from that link and turns off its notifications. Swipe left on a link to revoke or re-share it.")
                }
            }
        }
        .navigationTitle("Shared Vehicles")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in ActivityView(activityItems: [item.url]) }
    }

    private func revoke(_ token: ShareToken) {
        SharedLoggingImporter.shared.removeSubscription(for: token.token)
        modelContext.delete(token)
        try? modelContext.save()
    }

    private func reshare(_ token: ShareToken) {
        guard let vehicle = vehicles.first(where: { $0.id == token.vehicleID }) else { return }
        let descriptor = SharedVehicleDescriptor(
            token: token.token,
            vehicleID: vehicle.id,
            name: vehicle.name,
            make: vehicle.make,
            model: vehicle.model,
            year: vehicle.year,
            fuelTypeRaw: vehicle.fuelTypeRaw,
            fuelUnitRaw: vehicle.fuelUnitRaw,
            odometerUnitRaw: vehicle.odometerUnitRaw,
            currencyRaw: vehicle.currencyRaw
        )
        shareItem = VehicleShareItem(url: descriptor.shareURL)
    }
}
