import Foundation
import Testing
@testable import Changeover

/// Covers #0027's `AppSettings.preferredAudioLanguages`: it loads/persists
/// through an injected `UserDefaults` suite (never the real
/// `UserDefaults.standard` domain), normalizes on both load and save, and —
/// the case the existing `!v.isEmpty` string-loading idiom would get wrong —
/// an intentionally empty list is a real preference, distinct from "never
/// set", and survives a round trip as empty rather than reverting to the
/// `["eng", "spa"]` default.
@MainActor
struct AppSettingsTests {

    /// A fresh, disposable suite per test — never `UserDefaults.standard`.
    private func throwawaySuite(_ name: String = #function) -> UserDefaults {
        let suiteName = "AppSettingsTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToTheWorkflowDocsPreference() {
        let settings = AppSettings(defaults: throwawaySuite())
        #expect(settings.preferredAudioLanguages == ["eng", "spa"])
    }

    @Test func persistThenReloadRoundTripsTheList() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.preferredAudioLanguages = ["fra", "spa"]
        settings.persist()

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.preferredAudioLanguages == ["fra", "spa"])
    }

    /// The nil-versus-empty distinction the plan calls out explicitly: an
    /// empty list must survive, not silently revert to the default.
    @Test func anIntentionallyEmptyListSurvivesARoundTrip() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.preferredAudioLanguages = []
        settings.persist()

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.preferredAudioLanguages == [])
    }

    /// #0059 — AC3 5.1 passthru is opt-in, off by default.
    @Test func keepOriginalAudioTrackDefaultsToFalse() {
        let settings = AppSettings(defaults: throwawaySuite())
        #expect(settings.keepOriginalAudioTrack == false)
    }

    @Test func keepOriginalAudioTrackRoundTripsThroughPersist() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.keepOriginalAudioTrack = true
        settings.persist()

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.keepOriginalAudioTrack == true)
    }

    @Test func bibliographicCodesNormalizeOnSave() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.preferredAudioLanguages = ["FRE", "eng", "und"]
        settings.persist()

        // "und" normalizes to nil and is dropped; "FRE" becomes "fra".
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.preferredAudioLanguages == ["fra", "eng"])
    }
    // MARK: - The Details disclosure (docs/plain-language-ui.md §1.4)

    /// The app speaks plainly by default.
    @Test func showsDetailsDefaultsToFalse() {
        #expect(AppSettings(defaults: throwawaySuite()).showsDetails == false)
    }

    /// Opening Details once opens it everywhere and it stays open across
    /// launches — it is a preference, not a per-screen chore.
    @Test func showsDetailsRoundTripsThroughPersist() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.showsDetails = true
        settings.persist()
        #expect(AppSettings(defaults: defaults).showsDetails)
    }

    /// The disclosure writes immediately, and writes **only** its own key —
    /// so toggling it inside the Settings window never saves a half-typed
    /// API key the user has not pressed Save on.
    @Test func persistShowsDetailsWritesOnlyThatOneKey() {
        let defaults = throwawaySuite()
        let settings = AppSettings(defaults: defaults)
        settings.tmdbAPIKey = "half-typed"
        settings.showsDetails = true
        settings.persistShowsDetails()

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.showsDetails)
        #expect(reloaded.tmdbAPIKey.isEmpty)
    }

}
