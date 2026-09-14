// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Foundation

enum ArkFileWeatherFreshness: String, Codable, Equatable, Sendable {
    case clockUncertain
    case fresh
    case aging
    case stale
    case expired
    case historical
}

enum ArkFileWeatherConnectivity: String, Equatable, Sendable {
    case online
    case offline
    case unknown
}

enum ArkFileWeatherAlertEmphasis: String, Equatable, Sendable {
    case urgent
    case upcoming
    case caution
    case historical
}

enum ArkFileWeatherFreshnessSemantics {
    /// Small clock corrections are common. A rollback greater than this bound
    /// makes freshness unknowable and therefore ineligible for urgent styling.
    static let permittedClockRollback: TimeInterval = 5 * 60

    /// A pure classification based only on the persisted stamp and caller's
    /// clock. Boundaries are inclusive, avoiding flicker at exact timestamps.
    static func classify(
        stamp: ArkFileWeatherComponentStamp,
        at now: Date
    ) -> ArkFileWeatherFreshness {
        if now < stamp.fetchedAt.addingTimeInterval(-permittedClockRollback) {
            return .clockUncertain
        }
        if now <= stamp.freshUntil {
            return .fresh
        }
        if now <= stamp.agingUntil {
            return .aging
        }
        if now <= stamp.expiresAt {
            return .stale
        }
        if now <= stamp.historicalAt {
            return .expired
        }
        return .historical
    }
}

struct ArkFileWeatherAlertPresentation: Equatable, Sendable {
    let emphasis: ArkFileWeatherAlertEmphasis
    let isUrgent: Bool
    let cacheNotice: String?
}

enum ArkFileWeatherAlertPresentationSemantics {
    static let cachedAlertNotice =
        "This alert was active when ArkFile last checked. It may have changed or been cancelled."
    static let cachedUpcomingAlertNotice =
        "This alert was scheduled to become effective when ArkFile last checked. It may have changed or been cancelled."

    /// Expired or historical data can remain useful context, but it can never
    /// retain urgent visual treatment.
    static func presentation(
        for alert: ArkFileWeatherAlert,
        componentStamp: ArkFileWeatherComponentStamp,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> ArkFileWeatherAlertPresentation {
        let freshness = ArkFileWeatherFreshnessSemantics.classify(
            stamp: componentStamp,
            at: now
        )
        let active = alert.isActive(at: now)
        let upcoming = alert.isUpcoming(at: now)
        let severityIsUrgent = alert.severity == .severe || alert.severity == .extreme
        let urgencyIsCurrent = alert.urgency == .immediate || alert.urgency == .expected
        // Red urgent styling requires a recently checked alert component.
        // Official text can remain useful after that, but a stale cache must
        // not look like a live warning channel.
        let dataCanBeUrgent = freshness == .fresh || freshness == .aging
        let urgent = active && severityIsUrgent && urgencyIsCurrent && dataCanBeUrgent

        let emphasis: ArkFileWeatherAlertEmphasis
        if freshness == .clockUncertain
            || freshness == .expired
            || freshness == .historical
            || (!active && !upcoming) {
            emphasis = .historical
        } else if upcoming {
            emphasis = .upcoming
        } else if urgent {
            emphasis = .urgent
        } else {
            emphasis = .caution
        }

        let needsCacheNotice = connectivity != .online || freshness != .fresh
        let cacheNotice: String? = if needsCacheNotice {
            upcoming ? cachedUpcomingAlertNotice : cachedAlertNotice
        } else {
            nil
        }
        return ArkFileWeatherAlertPresentation(
            emphasis: emphasis,
            isUrgent: urgent,
            cacheNotice: cacheNotice
        )
    }

    /// Every successful-empty message names the check. Offline, stale, failed,
    /// unavailable, and unsupported states never collapse to an unqualified
    /// "No alerts."
    static func emptyStateMessage(
        for component: ArkFileWeatherComponent<[ArkFileWeatherAlert]>,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> String {
        switch component.availability {
        case .successfulEmpty:
            guard let stamp = component.stamp else {
                return "Alert status is unavailable."
            }
            let freshness = ArkFileWeatherFreshnessSemantics.classify(stamp: stamp, at: now)
            if connectivity == .online, freshness == .fresh {
                return "No active alerts as of the last check."
            }
            return "No alerts were active when ArkFile last checked. Conditions may have changed."
        case .failed:
            if component.value?.isEmpty == false {
                return "Alerts could not be updated. Showing alerts saved from an earlier check."
            }
            return "Alerts could not be updated. Current alert status is unknown."
        case .unavailable:
            return "Alert status is temporarily unavailable."
        case .unsupported:
            return "Official alerts are not supported for this saved location."
        case .available:
            if component.value?.isEmpty == true {
                return "Alert data is incomplete. Current alert status is unknown."
            }
            return "Official alert details are available."
        }
    }
}
