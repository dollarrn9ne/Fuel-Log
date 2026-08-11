import XCTest

final class Fuel_LogUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProbeMonthlyReport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()

        sleep(4)
        snapshot(app: app, name: "01_Dashboard")
        dump(app: app, tag: "DASHBOARD")

        let trips = app.buttons["TripsButton"]
        print("TRIPS_BUTTON_EXISTS=\(trips.exists)")
        XCTAssertTrue(trips.waitForExistence(timeout: 10), "TripsButton not found")
        trips.tap()
        sleep(2)
        snapshot(app: app, name: "02_Trips")
        dump(app: app, tag: "TRIPS")

        let rearTapped = tapLabeled("Monthly Reports", in: app)
        print("MONTHLY_REPORTS_TAPPED=\(rearTapped)")
        sleep(2)
        snapshot(app: app, name: "03_MonthlyReports")
        dump(app: app, tag: "REAR_VIEW")

        let cells = app.cells
        print("REAR_VIEW_CELL_COUNT=\(cells.count)")
        for (i, cell) in cells.allElementsBoundByIndex.enumerated() {
            print("REAR_VIEW_CELL_\(i)=\(cell.label)")
        }

        if cells.count > 0 {
            let first = cells.firstMatch
            print("TAPPING_FIRST_CELL=\(first.label)")
            first.tap()
            sleep(2)
            snapshot(app: app, name: "04_MonthlyReport")
            dump(app: app, tag: "MONTHLY_REPORT")

            print("MAP_COUNT=\(app.maps.count)")
            print("STATIC_TEXT_COUNT=\(app.staticTexts.count)")
            for t in app.staticTexts.allElementsBoundByIndex {
                print("TEXT=\(t.label)")
            }
        } else {
            print("NO_CELLS_FOUND")
        }
    }

    @discardableResult
    private func tapLabeled(_ label: String, in app: XCUIApplication) -> Bool {
        let candidates = [
            app.buttons[label],
            app.staticTexts[label],
            app.cells.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        ]
        for c in candidates {
            if c.waitForExistence(timeout: 5) && c.isHittable {
                c.tap()
                return true
            }
        }
        return false
    }

    private func dump(app: XCUIApplication, tag: String) {
        print("=====BEGIN_DUMP:\(tag)=====")
        print(app.debugDescription)
        print("=====END_DUMP:\(tag)=====")
    }

    private func snapshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
