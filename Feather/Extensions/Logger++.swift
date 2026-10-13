//
//  Logger++.swift
//  Feather
//
//  Created by samara on 24.05.2025.
//

import OSLog

extension Logger {
	static let signing = AppLogger(category: "签名")
	static let misc = AppLogger(category: "通用")
}
