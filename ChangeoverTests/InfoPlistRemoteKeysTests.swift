import Foundation
import Testing
@testable import Changeover

/// Covers #0074: `Changeover/Info.plist` must declare `NSLocalNetworkUsageDescription`
/// and `NSBonjourServices` so the Local Network permission prompt has real copy
/// and so Bonjour advertising doesn't silently fail once `RemoteServer` (#0068)
/// starts listening. `ChangeoverTests` is app-hosted (`BUNDLE_LOADER`/`TEST_HOST`
/// in the project point at `Changeover.app`), so `Bundle.main` here is the built
/// app bundle — the same merge of `GENERATE_INFOPLIST_FILE` build settings and
/// `Changeover/Info.plist` that ships. This also guards the merge itself: a key
/// set only in the file (not as an `INFOPLIST_KEY_*`) must still show up, and a
/// build-setting key (`INFOPLIST_KEY_LSUIElement`) must survive alongside it.
struct InfoPlistRemoteKeysTests {

    /// The Bonjour service type `Changeover/Info.plist` advertises. Kept as a
    /// literal here rather than a shared constant: the package that will own
    /// `RemoteConstants.bonjourServiceType` (#0061) doesn't exist yet, and this
    /// ticket is scoped to the Info.plist keys and this test only.
    private static let expectedBonjourServiceType = "_changeover._tcp"

    private static var infoDictionary: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    @Test func localNetworkUsageDescriptionIsPresentAndNonEmpty() {
        let description = Self.infoDictionary["NSLocalNetworkUsageDescription"] as? String
        #expect(description != nil)
        #expect(!(description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func bonjourServicesContainsExactlyTheChangeoverServiceType() {
        let services = Self.infoDictionary["NSBonjourServices"] as? [String]
        #expect(services == [Self.expectedBonjourServiceType])
    }

    /// Guards the `GENERATE_INFOPLIST_FILE` + `INFOPLIST_FILE` merge: adding
    /// keys to `Changeover/Info.plist` must not clobber `INFOPLIST_KEY_LSUIElement`
    /// (`project.pbxproj`), which keeps the app menu-bar-only with no Dock icon.
    @Test func lsuiElementIsStillTrue() {
        let value = Self.infoDictionary["LSUIElement"]
        let isTrue = (value as? Bool) == true || (value as? String) == "1" || (value as? NSNumber)?.boolValue == true
        #expect(isTrue)
    }
}
