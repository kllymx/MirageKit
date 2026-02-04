//
//  MirageSupportResources.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Access shared support resources bundled with MirageKit.
//

import Foundation

public enum MirageSupportResources {
    public static func colorSyncCleanupURL() -> URL? {
        Bundle.module.url(forResource: "If-Your-Computer-Feels-Stuttery", withExtension: "md")
    }

    public static func colorSyncCleanupMarkdown() -> String? {
        guard let url = colorSyncCleanupURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
