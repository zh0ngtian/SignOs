//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	@State private var _selection: TabEnum

	init() {
		__selection = State(initialValue: TabEnum.launchTab())
	}

	var body: some View {
		TabView(selection: $_selection) {
			ForEach(TabEnum.defaultTabs, id: \.self) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab) {
					TabEnum.view(for: tab)
				}
			}

			ForEach(TabEnum.customizableTabs, id: \.self) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab) {
					TabEnum.view(for: tab)
				}
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
	}
}
