//
//  SourceAppsView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date
		
		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true
	
	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?
	
	@State private var _refreshError: String?
	@State private var _isRefreshing = false
	@Environment(\.dismiss) private var dismiss
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@State private var _searchText = ""

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	private var _sourceContexts: [SourceRepositoryContext] {
		object.compactMap { source in
			guard !source.isDeleted, let repository = viewModel.sources[source] else { return nil }
			return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
		}
	}
	
	// MARK: Body
	var body: some View {
		ZStack {
			if !_sourceContexts.isEmpty {
				SourceAppsTableRepresentableView(
					sourceContexts: _sourceContexts,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					onSelect: {self._selectedRoute = $0},
					onRefresh: { await _refresh() }
				)
			} else if _isRefreshing {
				ProgressView("正在刷新软件源…")
			} else {
				ContentUnavailableView {
					Label("暂时无法加载应用", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
				} description: {
					Text(_refreshError ?? "点击重试以刷新软件源。")
				} actions: {
					Button("重试") { Task { await _refresh() } }
				}
			}
		}
		.navigationTitle(_navigationTitle)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar(.visible, for: .navigationBar)
		.searchable(text: $_searchText, placement: .platform())
		.toolbarTitleMenu {
			if dynamicTypeSize.isAccessibilitySize { _sortActions() }
			if _sourceContexts.count == 1 {
				if let url = _sourceContexts[0].repository.website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}
				
				if let url = _sourceContexts[0].repository.patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}
			
			Divider()
			
			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.map {
					$0.sourceURL?.absoluteString ?? ""
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			if !dynamicTypeSize.isAccessibilitySize {
				NBToolbarMenu(
					systemImage: "line.3.horizontal.decrease",
					style: .icon,
					placement: .topBarTrailing
				) {
					_sortActions()
				}
			}
			if object.count == 1, let source = object.first, !source.isDeleted {
				ToolbarItem(placement: .topBarTrailing) {
					NavigationLink {
						if let endpoint = CloudSourceEndpoint.managementURL(for: source.sourceURL) {
							CloudSourceManagerView(source: source, managementAddress: endpoint.absoluteString)
						} else {
							SourceManagementView(source: source, viewModel: viewModel)
						}
					} label: {
						Label("软件源设置", systemImage: "gearshape")
					}
					.accessibilityIdentifier("source-settings")
				}
			}
		}
		.onAppear {
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.task {
			if _sourceContexts.isEmpty { await _refresh() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)) { _ in
			if object.allSatisfy({ $0.isDeleted || $0.managedObjectContext == nil }) { dismiss() }
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(
				sourceURL: route.sourceURL,
				source: route.source,
				app: route.app
			)
		}
	}
	
	@MainActor
	private func _refresh() async {
		guard !_isRefreshing else { return }
		_isRefreshing = true
		_refreshError = nil
		defer { _isRefreshing = false }
		for source in object where !source.isDeleted {
			do { try await viewModel.refreshSource(source) }
			catch { _refreshError = error.localizedDescription }
		}
	}
	
	struct SourceRepositoryContext: Equatable {
		let sourceURL: URL?
		let repository: ASRepository
		
		static func == (lhs: SourceRepositoryContext, rhs: SourceRepositoryContext) -> Bool {
			lhs.sourceURL == rhs.sourceURL &&
			lhs.repository.id == rhs.repository.id &&
			lhs.repository.name == rhs.repository.name &&
			lhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" } ==
			rhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" }
		}
	}
	
	struct SourceAppRoute: Identifiable, Hashable {
		let sourceURL: URL?
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}
	
	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
