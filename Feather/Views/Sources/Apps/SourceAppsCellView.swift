//
//  SourceAppsCellView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import Combine

// thats a whole pharaghraph of codes
struct SourceAppsCellView: View {
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@AppStorage("Feather.storeCellAppearance") private var _storeCellAppearance: Int = 0
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	
	var body: some View {
		VStack {
			if dynamicTypeSize.isAccessibilitySize {
				appInfo
				installButton.frame(maxWidth: .infinity, alignment: .trailing)
			} else {
				HStack(spacing: 12) {
					appInfo
					installButton
				}
			}
			
			if
				_storeCellAppearance != 0,
				let desc = app.localizedDescription
			{
				Text(desc)
					.frame(maxWidth: .infinity, alignment: .leading)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.top, 2)
			}
		}
	}
	
	private var appInfo: some View {
		HStack(spacing: 18) {
			WSAppIcon(url: app.iconURL, size: 56)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				Text(app.currentName)
					.font(.headline)
					.foregroundStyle(.primary)
					.lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
				Text(Self.appDescription(app: app))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var installButton: some View {
		WSOneViewGetButton(sourceURL: sourceURL, source: source, app: app, idleTitle: "Install")
			.fixedSize(horizontal: true, vertical: false)
	}

	static func appDescription(app: ASRepository.App) -> String {
		let optionalComponents: [String?] = [
			app.currentVersion,
			app.currentDescription ?? .localized("An awesome application")
		]
		
		let components: [String] = optionalComponents.compactMap { value in
			guard
				let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
				!trimmed.isEmpty
			else {
				return nil
			}
			
			return trimmed
		}
		
		return components.joined(separator: " • ")
	}
}
