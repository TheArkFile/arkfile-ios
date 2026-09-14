// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileWeatherRefreshTrigger: String, Equatable, Sendable {
    case manual
    case openingBriefing
    case foreground
    case reconnect
    case background
}

enum ArkFileWeatherRefreshPolicyReason: String, Equatable, Sendable {
    case eligible
    case notConfigured
    case automaticRefreshDisabled
    case recentAttempt
    case stillFresh
    case providerBackoff
}

struct ArkFileWeatherRefreshPolicyDecision: Equatable, Sendable {
    let shouldRefresh: Bool
    let reason: ArkFileWeatherRefreshPolicyReason
    let nextEligibleAt: Date?

    static func refresh() -> Self {
        Self(shouldRefresh: true, reason: .eligible, nextEligibleAt: nil)
    }

    static func wait(
        _ reason: ArkFileWeatherRefreshPolicyReason,
        until date: Date? = nil
    ) -> Self {
        Self(shouldRefresh: false, reason: reason, nextEligibleAt: date)
    }
}

enum ArkFileWeatherRefreshPolicy {
    static let manualDebounce: TimeInterval = 5
    static let automaticAttemptCooldown: TimeInterval = 30
    static let openingFreshness: TimeInterval = 60 * 60
    static let foregroundFreshness: TimeInterval = 60 * 60
    static let reconnectFreshness: TimeInterval = 60 * 60
    static let backgroundFreshness: TimeInterval = 3 * 60 * 60
    static let backgroundEarliestInterval: TimeInterval = 3 * 60 * 60

    static func decision(
        trigger: ArkFileWeatherRefreshTrigger,
        settings: ArkFileWeatherSettings,
        snapshot: ArkFileWeatherSnapshot?,
        lastAttemptAt: Date?,
        providerRetryAfter: Date?,
        now: Date
    ) -> ArkFileWeatherRefreshPolicyDecision {
        guard let location = settings.savedLocation else {
            return .wait(.notConfigured)
        }

        if trigger.requiresAutomaticOptIn && !settings.automaticRefreshEnabled {
            return .wait(.automaticRefreshDisabled)
        }

        if let providerRetryAfter, now < providerRetryAfter {
            return .wait(.providerBackoff, until: providerRetryAfter)
        }

        if let lastAttemptAt {
            let cooldown = trigger == .manual
                ? manualDebounce
                : automaticAttemptCooldown
            let nextAttempt = lastAttemptAt.addingTimeInterval(cooldown)
            if now < nextAttempt {
                return .wait(.recentAttempt, until: nextAttempt)
            }
        }

        if trigger == .manual {
            return .refresh()
        }

        guard let snapshot,
              snapshot.locationRevision == location.revision,
              let lastCoreFetch = lastCoreSuccessfulFetch(in: snapshot) else {
            return .refresh()
        }
        let triggerDeadline = lastCoreFetch.addingTimeInterval(
            freshnessInterval(for: trigger)
        )
        let providerDeadline = coreStamps(in: snapshot)
            .map(\.freshUntil)
            .min() ?? triggerDeadline
        let refreshAfter = min(triggerDeadline, providerDeadline)
        if now < refreshAfter {
            return .wait(.stillFresh, until: refreshAfter)
        }
        return .refresh()
    }

    static func nextBackgroundRequestDate(
        after date: Date
    ) -> Date {
        date.addingTimeInterval(backgroundEarliestInterval)
    }

    private static func freshnessInterval(
        for trigger: ArkFileWeatherRefreshTrigger
    ) -> TimeInterval {
        switch trigger {
        case .manual:
            0
        case .openingBriefing:
            openingFreshness
        case .foreground:
            foregroundFreshness
        case .reconnect:
            reconnectFreshness
        case .background:
            backgroundFreshness
        }
    }

    /// The oldest successful core component governs aggregate freshness. This
    /// prevents a recent forecast from making an old alert check appear recent.
    private static func lastCoreSuccessfulFetch(
        in snapshot: ArkFileWeatherSnapshot
    ) -> Date? {
        let stamps = coreStamps(in: snapshot)
        guard stamps.count == 3 else { return nil }
        return stamps.map(\.fetchedAt).min()
    }

    private static func coreStamps(
        in snapshot: ArkFileWeatherSnapshot
    ) -> [ArkFileWeatherComponentStamp] {
        [
            snapshot.hourly.stamp,
            snapshot.daily.stamp,
            snapshot.alerts.stamp
        ].compactMap { $0 }
    }
}

private extension ArkFileWeatherRefreshTrigger {
    var requiresAutomaticOptIn: Bool {
        switch self {
        case .manual:
            false
        case .openingBriefing, .foreground, .reconnect, .background:
            true
        }
    }
}
