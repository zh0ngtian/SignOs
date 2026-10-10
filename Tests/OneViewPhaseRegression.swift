@main
struct OneViewPhaseRegression {
	static func main() {
		// Regression: a completed signing job or a failed installation must
		// leave an actionable Install button, never claim the app is installed.
		precondition(OneViewPhase.resolve(downloading: false, queued: false,
			signed: true, installed: false, imported: false) == .ready)
		precondition(OneViewPhase.resolve(downloading: false, queued: false,
			signed: true, installed: true, imported: false) == .installed)
		// A queued update takes precedence over a previous successful install.
		precondition(OneViewPhase.resolve(downloading: false, queued: true,
			signed: true, installed: true, imported: true) == .preparing)
		precondition(OneViewPhase.resolve(downloading: true, queued: true,
			signed: true, installed: true, imported: true) == .downloading)
		// An import left behind by a failed automatic signing job is retryable.
		precondition(OneViewPhase.resolve(downloading: false, queued: false,
			signed: false, installed: false, imported: true) == .needsSign)
		precondition(OneViewPhase.resolve(downloading: false, queued: false,
			signed: false, installed: false, imported: false) == .idle)
		print("OneView install state regressions: 6 passed")
	}
}
