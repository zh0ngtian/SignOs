//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews
import CoreData

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	private let purpose: ManualSigningFlow.Purpose
	private let onInstallReady: @MainActor (Signed) -> Void
	
	init(app: AppInfoPresentable, purpose: ManualSigningFlow.Purpose = .sign,
         onInstallReady: @escaping @MainActor (Signed) -> Void = { AutoSignManager.shared.enqueueInstall(app: $0) }) {
		self.app = app
		self.purpose = purpose
		self.onInstallReady = onInstallReady
		let existing = AppOperations.certificate(for: app, targetIdentifier: AppOperations.signingOptions(for: app).appIdentifier)
        let storedCert = existing.flatMap { cert in Storage.shared.getAllCertificates().firstIndex { $0.uuid == cert.uuid } } ?? UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
		__temporaryOptions = State(initialValue: Self._initialOptions(for: app, certificate: Storage.shared.getCertificate(for: storedCert), purpose: purpose))
	}

    private static func _initialOptions(for app: AppInfoPresentable, certificate: CertificatePair?, purpose: ManualSigningFlow.Purpose) -> Options {
        var options = AppOperations.signingOptions(for: app)
        let original = AppOperations.originalIdentifier(for: app)
        if purpose != .sourceInstall, original.flatMap({ AppBundleIdentifierPreferences.shared.configuredIdentifier(for: $0) }) == nil {
            if options.ppqProtection, certificate?.ppQCheck == true, let identifier = app.identifier {
                options.appIdentifier = "\(identifier).\(options.ppqString)"
            }
            if let identifier = app.identifier, let replacement = options.identifiers[identifier] {
                options.appIdentifier = replacement
            }
        }
        if let name = app.name, let replacement = options.displayNames[name] { options.appName = replacement }
        return options
    }
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_appHeader(for: app)
				_identitySection(for: app)
				_cert()
				_customizationProperties(for: app)
			}
			.safeAreaInset(edge: .bottom) {
				_signButton()
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Label(.localized("Signing"), systemImage: "signature")
						.font(.headline)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = Self._initialOptions(for: app, certificate: _selectedCert(), purpose: purpose)
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
			.simultaneousGesture(
				DragGesture(minimumDistance: 25)
					.onEnded { value in
						guard
							value.startLocation.x < 44,
							value.translation.width > 60,
							abs(value.translation.height) < 60
						else { return }
						dismiss()
					}
			)
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _appHeader(for app: AppInfoPresentable) -> some View {
		Section {
			HStack(spacing: 16) {
				Menu {
					Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
					Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
					Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
				} label: {
					if let icon = appIcon {
						Image(uiImage: icon)
							.appIconStyle()
					} else {
						FRAppIconView(app: app, size: 64)
					}
				}

				VStack(alignment: .leading, spacing: 4) {
					Text(_temporaryOptions.appName ?? app.name ?? .localized("App"))
						.font(.title3.weight(.bold))
						.lineLimit(2)
					Text(verbatim: _temporaryOptions.appVersion ?? app.version ?? "")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

				Spacer()
			}
			.padding(.vertical, 4)
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private func _identitySection(for app: AppInfoPresentable) -> some View {
		Section {
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
            LabeledContent(.localized("Identifier")) {
                Text(_temporaryOptions.appIdentifier ?? app.identifier ?? "")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		} header: {
			Text(.localized("Identity"))
		} footer: {
            Text("Bundle ID 使用本机配置，请在软件源设置中修改。")
		}
	}
	
	@ViewBuilder
	private func _signButton() -> some View {
		VStack(spacing: 0) {
			Divider()
			HStack {
				Button {
					_start()
				} label: {
					HStack(spacing: 8) {
						if _isSigning {
							ProgressView()
								.tint(.white)
						} else {
							Image(systemName: "signature")
						}
						Text(verbatim: _isSigning ? .localized("Signing") : .localized(purpose == .sourceInstall ? "Sign & Install" : "Sign"))
							.font(.headline)
					}
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity, minHeight: 50)
					.background(
						RoundedRectangle(cornerRadius: 16, style: .continuous)
							.fill(.tint)
					)
					.opacity(_isSigning ? 0.7 : 1.0)
				}
				.buttonStyle(.plain)
				.disabled(_isSigning)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background(.bar)
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					HStack(spacing: 12) {
						Image(systemName: cert.revoked ? "exclamationmark.shield.fill" : "checkmark.seal.fill")
							.font(.title3)
							.foregroundStyle(cert.revoked ? Color.red : Color.accentColor)
						VStack(alignment: .leading, spacing: 3) {
							Text(cert.nickname ?? .localized("Certificate"))
								.font(.body.weight(.semibold))
								.foregroundStyle(.primary)
								.lineLimit(1)
							if cert.revoked {
								Text(.localized("Revoked — pick another certificate"))
									.font(.caption)
									.foregroundStyle(.red)
							} else if let expiration = cert.expiration {
								Text(verbatim: .localized("Expires %@").replacingOccurrences(of: "%@", with: expiration.formatted(date: .abbreviated, time: .omitted)))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						Spacer()
					}
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			NavigationLink(.localized("Existing Dylibs")) {
				SigningDylibView(
					app: app,
					options: $_temporaryOptions.optional()
				)
			}
			
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(
					app: app,
					options: $_temporaryOptions.optional()
				)
			}
			#if NIGHTLY || DEBUG
				NavigationLink(.localized("Entitlements (Beta)")) {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
			#endif
			NavigationLink(.localized("Tweaks")) {
				SigningTweaksView(
					options: $_temporaryOptions
				)
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
        guard AppOperations.isAllowed(app) else {
            AppOperations.showError(AppOperations.sourceStatus(app) ?? "来源不可用。")
            return
        }
        let identifiers = Set([app.identifier, _temporaryOptions.appIdentifier].compactMap { $0 })
        let jobs = AutoSignManager.shared.queue + (AutoSignManager.shared.currentJob.map { [$0] } ?? [])
        if SourceAccessManager.shared.isInUse(app.uuid) || jobs.contains(where: {
            $0.appUUID == app.uuid || $0.appIdentifier.map(identifiers.contains) == true
        }) || identifiers.contains(where: SourceAccessManager.shared.hasActiveApplication) {
            AppOperations.showError("这个应用正在处理，请等待当前任务结束。"); return
        }
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

        let options: Options
        do {
            options = try ManualSigningFlow.prepare(_temporaryOptions, for: app, purpose: purpose)
        } catch {
            AppOperations.showError(error.localizedDescription)
            return
        }

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true
		
		FR.signPackageFile(
			app,
			using: options,
			icon: appIcon,
			certificate: _selectedCert()
		) { error in
			_isSigning = false
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel)
				
				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
                UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
                AutoUpdateManager.shared.updateBadgeFromState()
                do {
                    if let result = try ManualSigningFlow.installationResult(for: app, options: options, purpose: purpose) {
                        onInstallReady(result)
                    }
                } catch {
                    AppOperations.showError(error.localizedDescription)
                    return
                }
				dismiss()
			}
		}
	}
}
