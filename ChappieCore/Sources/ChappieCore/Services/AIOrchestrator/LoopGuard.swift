import Foundation

/// Detects a model that keeps repeating the same tool call and getting the same answer.
///
/// This is the only automatic runaway protection now that the step cap is gone (besides the Stop
/// button), so it must not punish legitimate repeats: polling `git_status`, re-checking a build.
/// A repeat only counts while the RESULT is identical; any change in the result is progress and
/// restarts the count. The third identical call in a row (two identical results already seen) is blocked.
struct LoopGuard {

    /// Identical calls with identical results that are tolerated before the next one is blocked.
    static let allowedIdenticalResults = 2

    private var lastSignature: String?
    private var lastResultHash: Int?
    private var identicalResults = 0

    /// True when running `signature` would be the 3rd identical call with an unchanged result.
    func shouldBlock(signature: String) -> Bool {
        signature == lastSignature && identicalResults >= Self.allowedIdenticalResults
    }

    /// Records a call that actually ran. Blocked calls must NOT be recorded: they did not run,
    /// and recording them would keep the guard locked forever.
    mutating func record(signature: String, result: String) {
        let hash = result.hashValue
        if signature == lastSignature, hash == lastResultHash {
            identicalResults += 1
        } else {
            identicalResults = 1
        }
        lastSignature = signature
        lastResultHash = hash
    }

    /// Text returned to the model instead of running the call. Explains WHY, so it can change course.
    static func blockedMessage(toolName: String) -> String {
        """
        LOOP GUARD: `\(toolName)` was NOT run. You already called it \(allowedIdenticalResults) times in a row \
        with exactly the same arguments and got exactly the same result each time, so a third call cannot \
        tell you anything new.
        What to do instead: use the result you already have; or change the arguments; or call a different tool; \
        or, if you are stuck, stop and tell the user what is blocking you.
        """
    }
}
