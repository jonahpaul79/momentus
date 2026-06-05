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
        let center = UNUserNotificationCenter.current()
        center.delegate = WatchNotificationHandler.shared
        let action = UNNotificationAction(
            identifier: "startRecordingAction",
            title: "Record",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "meetingReminder",
                actions: [action],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
