//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case sources
	case search
	case library
	case updates
	case settings
	case certificates

	var title: String {
		switch self {
		case .sources: 	return .localized("Sources")
		case .search: 		return .localized("Search")
		case .library: 		return .localized("Library")
		case .updates: 		return .localized("Updates")
		case .settings: 	return .localized("Settings")
		case .certificates:	return .localized("Certificates")
		}
	}

	var icon: String {
		switch self {
		case .sources: 	return "externaldrive.fill"
		case .search: 		return "magnifyingglass"
		case .library: 		return "square.stack.3d.up.fill"
		case .updates: 		return "arrow.triangle.2.circlepath"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}

	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .sources: SourcesView()
		case .search: SearchView()
		case .library: LibraryView()
		case .updates: UpdatesView()
		case .settings: SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}

	static func launchTab(in defaults: UserDefaults = .standard) -> TabEnum {
		let stored = defaults.string(forKey: "SignOs.defaultTab")
		let tab = stored.flatMap(TabEnum.init(rawValue:)) ?? .sources
		let launchTab = defaultTabs.contains(tab) ? tab : .sources
		if stored != launchTab.rawValue {
			defaults.set(launchTab.rawValue, forKey: "SignOs.defaultTab")
		}
		return launchTab
	}

	static var defaultTabs: [TabEnum] {
		return [
			.sources,
			.search,
			.library,
			.updates,
			.settings
		]
	}

	static var customizableTabs: [TabEnum] {
		return [
			.certificates
		]
	}
}
