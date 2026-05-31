//
//  MomentusApp.swift
//  Momentus Watch App
//
//  Created by Jonah Paul on 5/28/26.
//

import SwiftUI
import UserNotifications

@main
struct Momentus_Watch_AppApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = WatchNotificationHandler.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
