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
        updateAdBlueReminder(for: vehicle)
        
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

    // MARK: - AdBlue / DEF refill

    /// When the tank is predicted to reach the "low" mark, or nil when there's
    /// nothing to predict from. Pure so the arithmetic can be checked on its own.
    ///
    /// - Parameters:
    ///   - remainingVolume / capacity / consumptionPer1000: from `AdBlueInsights`
    ///     (volume in the vehicle's fluid unit, use per 1,000 odometer units).
    ///   - distancePerDay: recent average driving, in odometer units.
    ///   - now: `AdBlueInsights` estimates the level as of the latest odometer
    ///     reading, so the countdown to "low" starts from here.
    static func adBlueReminderDate(remainingVolume: Double, capacity: Double, consumptionPer1000: Double, distancePerDay: Double, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard capacity > 0, consumptionPer1000 > 0, distancePerDay > 0 else { return nil }
        let lowVolume = capacity * AdBlueInsights.lowFraction
        let volumePerDistance = consumptionPer1000 / 1000
        let distanceUntilLow = (remainingVolume - lowVolume) / volumePerDistance
        // Already low (or about to be): nudge tomorrow morning.
        var target = distanceUntilLow <= 0
            ? now.addingTimeInterval(86400)
            : now.addingTimeInterval(distanceUntilLow / distancePerDay * 86400)
        if target <= now { target = now.addingTimeInterval(86400) }
        // Same 2-year ceiling as the maintenance reminder.
        if let maxDate = calendar.date(byAdding: .year, value: 2, to: now), target > maxDate { target = maxDate }
        return target
    }

    /// Schedules one notification for when this vehicle's AdBlue / DEF should be
    /// getting low. Needs a full top-up, a tank size and enough driving history
    /// for `AdBlueInsights` to estimate the level - otherwise it just clears.
    private func updateAdBlueReminder(for vehicle: Vehicle) {
        let center = UNUserNotificationCenter.current()
        let identifier = "adblue_\(vehicle.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard vehicle.usesAdBlue, !vehicle.isArchived else { return }
        let insights = AdBlueInsights(vehicle: vehicle)
        guard let remaining = insights.remainingVolume,
              let capacity = vehicle.adBlueCapacity,
              let rate = insights.consumptionPer1000 else { return }

        // Average distance driven per day across every logged odometer reading.
        let readings = ((vehicle.fillUps ?? []).compactMap { f in f.odometer.map { (f.date, $0) } }
                        + (vehicle.services ?? []).map { ($0.date, $0.odometer) })
            .sorted { $0.0 < $1.0 }
        guard let first = readings.first, let last = readings.last,
              last.0.timeIntervalSince(first.0) > 86400, last.1 > first.1 else { return }
        let perDay = (last.1 - first.1) / (last.0.timeIntervalSince(first.0) / 86400)

        guard let target = Self.adBlueReminderDate(remainingVolume: remaining, capacity: capacity, consumptionPer1000: rate, distancePerDay: perDay) else { return }

        let fluid = AdBlueNaming.name
        let content = UNMutableNotificationContent()
        content.title = "\(vehicle.name) \(fluid)"
        content.body = "Your \(fluid) is estimated to be running low. Top it up soon so you don't hit a warning or a speed limit."
        content.sound = .default

        let day = Calendar.current.dateComponents([.year, .month, .day], from: target)
        var trigger = DateComponents()
        trigger.year = day.year
        trigger.month = day.month
        trigger.day = day.day
        trigger.hour = 9 // 9 AM

        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: trigger, repeats: false)
        ))
    }
}
