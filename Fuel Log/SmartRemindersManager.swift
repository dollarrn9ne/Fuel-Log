import UserNotifications
import FuelLogShared

final class SmartRemindersManager: Sendable {
    static let shared = SmartRemindersManager()
    
    func requestPermission(completion: @escaping @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }
    
    func updateReminders(for vehicle: Vehicle) {
        let center = UNUserNotificationCenter.current()
        let identifier = "maint_\(vehicle.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        
        if vehicle.isArchived { return }
        
        let relevantServices = vehicle.fuelType == .electric ? (vehicle.services ?? []) : (vehicle.services ?? []).filter({ $0.type == .oilChange })
        let lastServiceOdo = relevantServices.map(\.odometer).max() ?? 0
        let lastServiceDate = relevantServices.map(\.date).max() ?? vehicle.purchaseDate ?? Date()
        
        // ----- Mileage-based due date -----
        // Predict when the driver will hit the mileage interval (e.g. 5,000 mi)
        // based on their average distance driven per day.
        let nextServiceOdo = lastServiceOdo + vehicle.maintenanceInterval
        
        // Find average distance driven per day
        let fills = (vehicle.fillUps ?? []).compactMap { f -> (Date, Double)? in
            guard let o = f.odometer else { return nil }
            return (f.date, o)
        }
        let svcs = (vehicle.services ?? []).map { ($0.date, $0.odometer) }
        let allLogs = (fills + svcs).sorted { $0.0 < $1.0 }
        
        var mileagePredictedDate: Date?
        
        if let currentOdo = vehicle.lastOdometer {
            let remainingOdo = nextServiceOdo - currentOdo
            if let first = allLogs.first, let last = allLogs.last, last.0.timeIntervalSince(first.0) > 86400 {
                let days = last.0.timeIntervalSince(first.0) / 86400.0
                let odoDiff = last.1 - first.1
                if odoDiff > 0 {
                    let odoPerDay = odoDiff / days
                    let daysRemaining = remainingOdo / odoPerDay
                    mileagePredictedDate = last.0.addingTimeInterval(daysRemaining * 86400)
                }
            }
        }
        
        // ----- Time-based due date -----
        // Fixed calendar window since the last relevant service (e.g. 6 months).
        // Reminders use whichever of the two is reached first.
        let timeBasedDate = Calendar.current.date(byAdding: .month, value: max(1, Int(vehicle.maintenanceIntervalMonths)), to: lastServiceDate)!
        
        var targetDate = mileagePredictedDate ?? timeBasedDate
        if let md = mileagePredictedDate, md < timeBasedDate { targetDate = md }
        
        // If already overdue (either by mileage or time), remind them tomorrow morning
        if targetDate <= Date() {
            targetDate = Date().addingTimeInterval(86400)
        }
        
        // Cap it at a maximum of 2 years out so we don't schedule unreasonable future alerts
        let maxDate = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        if targetDate > maxDate { targetDate = maxDate }
        
        let content = UNMutableNotificationContent()
        content.title = "\(vehicle.name) Maintenance"
        if vehicle.fuelType == .electric {
            content.body = "Your EV is approaching its next scheduled inspection interval. Time to book an appointment!"
        } else {
            let intervalText = "\(Int(vehicle.maintenanceInterval)) \(vehicle.odometerUnit.rawValue)"
            let monthsText = "\(Int(vehicle.maintenanceIntervalMonths)) months"
            content.body = "Due within \(intervalText) or \(monthsText), whichever comes first. Based on your recent driving, time to book an appointment!"
        }
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day], from: targetDate)
        var triggerComponents = DateComponents()
        triggerComponents.year = components.year
        triggerComponents.month = components.month
        triggerComponents.day = components.day
        triggerComponents.hour = 9 // 9 AM
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        center.add(request)
    }
}
