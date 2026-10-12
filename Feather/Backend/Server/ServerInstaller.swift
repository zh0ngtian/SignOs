//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?
	private var _progressTask: Task<Void, Never>?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) throws {
		self.app = app
		self.viewModel = viewModel
		try _setup()
		try _configureRoutes()
		try _server?.server.start()
		_needsShutdown = true
	}
	
	deinit {
		_progressTask?.cancel()
		_shutdownServer()
	}
	
	private func _setup() throws {
		self._server = try? setupApp(port: port)
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
			if case .installing = newStatus {
				self._startProgressMonitoring()
			} else if case .broken = newStatus {
				self._progressTask?.cancel()
				self._progressTask = nil
			}
		}
	}
		
	/// Shared by manual installation and the automatically retained local server.
	@MainActor
	private func _startProgressMonitoring() {
		guard _progressTask == nil else { return }
		_progressTask = Task { @MainActor [weak self] in
			var tracker = InstallProgressTracker()
			while !Task.isCancelled {
				guard let keepMonitoring = self?._pollProgress(tracker: &tracker), keepMonitoring else { return }
				do {
					try await Task.sleep(nanoseconds: 250_000_000)
				} catch { return }
			}
		}
	}

	@MainActor
	private func _pollProgress(tracker: inout InstallProgressTracker) -> Bool {
		guard let identifier = app.identifier else { return false }
		switch viewModel.status {
		case .broken, .completed: return false
		case .installing: break
		default: return true // A repeated manifest/payload request can temporarily change the status.
		}
		let rawProgress = UIApplication.installProgress(for: identifier)
		if tracker.observe(rawProgress) {
			// Progress disappearing is a cleanup signal, not proof of the installed version.
			Storage.shared.finishInstallCleanup(for: app)
			viewModel.installProgress = 1
			viewModel.status = .completed(.success(()))
			_progressTask = nil
			return false
		}
		viewModel.installProgress = tracker.hasStarted
			? min(1, max(0, ((rawProgress ?? 0) - 0.6) / 0.3)) : 0
		return true
	}

	func getServerMethod() -> Int {
		InstallationDefaults.serverMethod()
	}
	
	func getIPFix() -> Bool {
		InstallationDefaults.onlyLocalhost()
	}
}
