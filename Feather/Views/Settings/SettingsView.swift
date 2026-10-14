//
//  SettingsView.swift
//  Feather
//
//  Production-grade settings, Apple Settings-style icon tiles.
//

import SwiftUI
import NimbleViews
import UIKit
import IDeviceSwift

// MARK: - Icon tile (Settings.app style colored square)
struct WSIconTile: View {
	let systemImage: String
	var color: Color = .accentColor

	var body: some View {
		Image(systemName: systemImage)
			.font(.system(size: 14, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 28, height: 28)
			.background(
				RoundedRectangle(cornerRadius: 6.5, style: .continuous)
					.fill(color)
			)
	}
}

// MARK: - View
struct SettingsView: View {
	@AppStorage("SignOs.biometricLock") private var _biometricLock: Bool = false
	@AppStorage("SignOs.defaultTab") private var _defaultTabRaw: String = TabEnum.sources.rawValue

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_profile()
				_general()
				_data()
				_signing()
				_appearance()
				_privacy()
				_misc()
				_danger()
				_footer()
			}
		}
	}
}

// MARK: - Sections
extension SettingsView {
	@ViewBuilder
	private func _profile() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				HStack(spacing: 16) {
					FRAppIconView(size: 58)

					VStack(alignment: .leading, spacing: 3) {
						Text("SignOs")
							.font(.title2.weight(.bold))
						Text(.localized("Made By @ihateios / @zh0ngtian"))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}

					Spacer()

					Text(verbatim: Bundle.main.version)
						.font(.caption.weight(.bold))
						.foregroundStyle(.tint)
						.padding(.horizontal, 9)
						.padding(.vertical, 4)
						.background(Capsule().fill(Color.accentColor.opacity(0.12)))
				}
				.padding(.vertical, 6)
			}
		}
	}

	@ViewBuilder
	private func _general() -> some View {
		Section {
			Picker(selection: $_defaultTabRaw) {
				Text(.localized("Sources")).tag(TabEnum.sources.rawValue)
				Text("应用").tag(TabEnum.library.rawValue)
				Text(.localized("Settings")).tag(TabEnum.settings.rawValue)
			} label: {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "rectangle.on.rectangle", color: .blue)
					Text(.localized("Launch Tab"))
				}
			}
		} header: {
			Text(.localized("General"))
		} footer: {
			Text(.localized("The tab SignOs opens every time you launch it."))
		}
	}

	@ViewBuilder
	private func _data() -> some View {
		Section {
			NavigationLink(destination: CertificatesView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "checkmark.seal.fill", color: .green)
					Text(.localized("Certificates"))
				}
			}

			NavigationLink(destination: StorageView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "internaldrive.fill", color: .blue)
					Text(.localized("Storage"))
				}
			}

			NavigationLink(destination: LogsView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "doc.text.magnifyingglass", color: .teal)
					Text("日志")
				}
			}
			.accessibilityIdentifier("settings-logs")

			NavigationLink(destination: ActivityView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "clock.arrow.circlepath", color: .indigo)
					Text(.localized("Activity"))
				}
			}

			NavigationLink(destination: CertHealthView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "stethoscope", color: .red)
					Text(.localized("Certificate Health"))
				}
			}

			NavigationLink(destination: BackupRestoreView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "arrow.up.arrow.down.square.fill", color: .brown)
					Text(.localized("Backup & Restore"))
				}
			}
		} header: {
			Text(.localized("Data"))
		} footer: {
			Text(.localized("Certificates used for signing apps, and storage used by the app."))
		}
	}

	@ViewBuilder
	private func _signing() -> some View {
		Section {
			NavigationLink(destination: ConfigurationView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "slider.horizontal.3", color: .purple)
					Text(.localized("Signing Options"))
				}
			}
			NavigationLink(destination: ArchiveView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "archivebox.fill", color: .orange)
					Text(.localized("Archive & Compression"))
				}
			}
			NavigationLink(destination: InstallationView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "arrow.down.circle.fill", color: .blue)
					Text(.localized("Installation"))
				}
			}
			NavigationLink(destination: TweakVaultView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "puzzlepiece.extension.fill", color: .mint)
					Text(.localized("Tweak Vault"))
				}
			}
		} header: {
			Text(.localized("Signing"))
		} footer: {
			Text(.localized("Fine-tune how apps are installed, compressed and modified."))
		}
	}

	@ViewBuilder
	private func _appearance() -> some View {
		Section {
			NavigationLink(destination: AppearanceView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "paintbrush.fill", color: .pink)
					Text(.localized("Appearance"))
				}
			}
		} header: {
			Text(.localized("Appearance"))
		}
	}

	@ViewBuilder
	private func _privacy() -> some View {
		Section {
			Toggle(isOn: $_biometricLock) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "faceid", color: .blue)
					Text(.localized("Face ID Lock"))
				}
			}
			.tint(.accentColor)
		} header: {
			Text(.localized("Privacy"))
		} footer: {
			Text(.localized("Require Face ID to open SignOs."))
		}
	}

	@ViewBuilder
	private func _misc() -> some View {
		Section {
			Button {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			} label: {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "folder.fill", color: .yellow)
					Text(.localized("Open Documents"))
				}
			}
			.foregroundStyle(.primary)

			Button {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			} label: {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "archivebox.fill", color: .orange)
					Text(.localized("Open Archives"))
				}
			}
			.foregroundStyle(.primary)
		} header: {
			Text(.localized("Files"))
		}
	}

	@ViewBuilder
	private func _danger() -> some View {
		Section {
			NavigationLink(destination: ResetView()) {
				HStack(spacing: 12) {
					WSIconTile(systemImage: "trash.fill", color: .red)
					Text(.localized("Reset"))
						.foregroundStyle(.red)
				}
			}
		}
	}

	@ViewBuilder
	private func _footer() -> some View {
		Section {
			Text(verbatim: "SignOs \(Bundle.main.version) • \(String.localized("Made By @ihateios / @zh0ngtian"))")
				.font(.footnote)
				.foregroundStyle(.tertiary)
				.frame(maxWidth: .infinity, alignment: .center)
				.listRowBackground(Color.clear)
		}
	}
}
