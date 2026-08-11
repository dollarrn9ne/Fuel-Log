# Shared Logging (Borrow-a-Car) — Setup & Testing

One-way relay so someone borrowing a vehicle can log a fill-up from the **App Clip**
and have it land in the owner's account. No cross-account CloudKit sharing (CKShare)
is used, so the app stays on SwiftData.

## How it works

1. **Owner shares** a vehicle from the dashboard share icon. This creates a random
   `ShareToken`, persists it (SwiftData), registers a silent-push subscription for
   that token, and presents a share link:
   `https://inputfuellog.app/?token=<uuid>&vehicle=<uuid>&name=…&fuelUnit=…&odoUnit=…&currency=…`
2. **Borrower opens the link** → the App Clip parses the `SharedVehicleDescriptor`,
   shows a scoped "Log Fuel" form for just that vehicle (works with an empty clip
   store), and on Save writes a `FuelSubmission` record to the **public** CloudKit
   database, tagged with the token.
3. **Owner's app imports**: on launch/foreground (and via silent push) it queries
   the public DB for submissions matching its active tokens, creates fill-ups,
   dedupes by `clientSubmissionID`, refreshes the widget snapshot, posts a local
   notification, and best-effort deletes the processed records.
4. **Revoke** in Settings → Sharing → Shared Vehicles (swipe a row): deletes the
   token and removes its push subscription, so later submissions are ignored.

Key code:
- `FuelLogShared/Sources/FuelLogShared/SharedLoggingRelay.swift` — link + record model.
- `FuelLogShared/…/FuelLogModels.swift` — `ShareToken` (in `sharedSchema`).
- App Clip: `AppClipRootView.swift`, `AppClipFuelEntryView.swift` (`.shared` mode).
- Main app: `MainDashboardView.swift` (share action), `Fuel_LogApp.swift`
  (`SharedLoggingImporter` + `AppDelegate` remote-notification handling),
  `SettingsView.swift` (`SharedLinksView` revoke/re-share).

## Required CloudKit Console setup (before this works)

The relay uses the app's existing container `iCloud.com.Motosung.Fuel-Log`,
**public database**. You must create the schema there:

1. In the [CloudKit Console](https://icloud.developer.apple.com) → your container →
   **Schema** (Development).
2. Add a **Record Type** named `FuelSubmission` with fields:
   | Field | Type |
   |---|---|
   | `token` | String |
   | `vehicleID` | String |
   | `date` | Date/Time |
   | `odometer` | Double |
   | `volume` | Double |
   | `pricePerUnit` | Double |
   | `isFullTank` | Int64 |
   | `unitRaw` | String |
   | `notes` | String |
   | `locationName` | String |
   | `submittedAt` | Date/Time |
   | `clientSubmissionID` | String |
   (Saving one record from a debug build also auto-creates the type/fields in
   Development; you still need the index below.)
3. Mark `token` as **Queryable** (Indexes tab). The importer queries
   `token == <uuid>`; without the index the query fails.
4. Public database security: the default `_world` "create" role lets borrowers
   write. The owner did not create these records, so **owner-side delete may be
   denied** — that's fine (the dedupe set prevents re-import); records may linger.
5. When ready to ship: **Deploy Schema Changes to Production** in the Console.

## App Store Connect / associated domain (App Clip launch)

Separate from the code (already noted): configure the App Clip Experience and the
AASA `appclips` section for `inputfuellog.app` at publish time. The entitlement
`appclips:inputfuellog.app` is already set on both targets.

## Testing without AASA (invocation URL)

You can exercise the borrower flow in Xcode without a server:
- Edit the **FuelLogAppClip** scheme → Run → Arguments → **App Clip invocation URL**,
  e.g. a real share link copied from the owner app.
- Xcode injects it via `_XCAppClipURL`, so the clip behaves as if launched from the link.

## Two-device end-to-end test (needs two Apple IDs)

CKShare-free, but still requires real iCloud accounts + network — the simulator
can't fully exercise it.

1. **Device A (owner)**: sign into iCloud, create/select a vehicle (e.g. RAV4),
   tap the dashboard **share** icon → send yourself/Device B the link.
2. **Device B (borrower, different Apple ID)**: open the link → App Clip shows only
   that vehicle → log a fill-up → Save. Confirm success (needs iCloud sign-in).
3. **CloudKit Console** (public DB): confirm a `FuelSubmission` record appeared.
4. **Device A**: foreground the app → the fill-up imports onto the vehicle, a local
   notification fires, and the record is (best-effort) removed. With push working,
   this happens in the background within seconds.
5. **Edge cases to verify**:
   - Borrower not signed into iCloud / offline → friendly error, no crash.
   - Duplicate submit (same link twice) → imported once (dedupe).
   - Revoke the link in Settings → later submissions are ignored.
   - Borrower never sees the owner's other vehicles.

## Known tradeoffs

- **One-way** by design (borrower adds; owner sees). Borrower doesn't see history.
- **Public DB** data is low-sensitivity but world-readable; tokens are random and
  records are deleted after import where permitted. Consider encrypting the payload
  or adding an approve-before-import step if needed.
- Anyone with a link can submit to that vehicle; tokens are unguessable and revocable.
