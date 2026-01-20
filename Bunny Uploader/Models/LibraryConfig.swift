//
//  LibraryConfig.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation

struct LibraryConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var libraryId: String
    var pullZoneHost: String? = nil
}
