import Foundation
import PitboxKit

// Small helpers for the Fetch file sheet, so it never has to match words itself.

extension FetchPlan {
    /// "Try as alex": the fetch logged in as the reply's user, the server did not accept the key for it, and
    /// the config's user is another one. The sheet then re-plans with `loginUser: configUser` and re-arms.
    func offersTryAsConfigUser(after outcome: FetchFileOutcome) -> Bool {
        guard case .failed(let reason) = outcome, let configUser, configUser != loginUser else { return false }
        return reason == FetchFailure.keyRejected.words(alias: alias, user: loginUser, fileName: fileName,
                                                        limits: FetchLimits())
    }

    /// The extension the sheet names after the file ("ends in .md"), nil when the name has none.
    var fileExtension: String? {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }
}

extension FetchLimits {
    /// The sheet's "Limits" line: "up to 500 MB and 10 minutes".
    var sheetLine: String {
        let minutes = Int((totalDeadline / 60).rounded())
        return "up to \(maxFileBytes / 1_048_576) MB and \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
