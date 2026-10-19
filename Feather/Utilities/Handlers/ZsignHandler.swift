//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignSwift
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		let museumPlan: MuseumMuseAppGroupSigning.Plan?
		if Bundle(url: _appUrl)?.bundleIdentifier == MuseumMuseAppGroupSigning.bundleIdentifier {
			let profile = Storage.shared.getProvisionFileDecoded(for: cert)
			let groups = profile?.Entitlements?[MuseumMuseAppGroupSigning.entitlementKey]?.value as? [String] ?? []
			let customEntitlements: [String: Any]?
			if let url = _options.appEntitlementsFile {
				let data = try Data(contentsOf: url)
				guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
					throw MuseumMuseAppGroupSigning.Failure.customEntitlementsMismatch
				}
				customEntitlements = values
			} else {
				customEntitlements = nil
			}
			let previousGroup = await MainActor.run {
				guard let previous = AppOperations.installed(for: MuseumMuseAppGroupSigning.bundleIdentifier),
				      let url = Storage.shared.getAppDirectory(for: previous) else { return nil as String? }
				return Bundle(url: url)?.object(forInfoDictionaryKey: MuseumMuseAppGroupSigning.runtimeGroupKey) as? String
			}
			museumPlan = try MuseumMuseAppGroupSigning.prepare(appURL: _appUrl, profileGroups: groups,
				customEntitlements: customEntitlements, previousRuntimeGroup: previousGroup)
			try museumPlan?.apply()
		} else {
			museumPlan = nil
		}
		let succeeded = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? "",
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)
		if let museumPlan {
			if let hadError { throw hadError }
			guard succeeded else { throw MuseumMuseAppGroupSigning.Failure.signingFailed }
			try museumPlan.validateSigned()
		}
	}
	
	func adhocSign() async throws {
		let _ = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)
	}
}
