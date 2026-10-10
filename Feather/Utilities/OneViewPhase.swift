// A signed archive is ready to install; it is not proof of installation.
enum OneViewPhase: Equatable {
	case idle, downloading, preparing, needsSign, ready, installed

	static func resolve(downloading: Bool, queued: Bool, signed: Bool,
						installed: Bool, imported: Bool) -> Self {
		if downloading { return .downloading }
		if queued { return .preparing }
		if signed { return installed ? .installed : .ready }
		if imported { return .needsSign }
		return .idle
	}
}
