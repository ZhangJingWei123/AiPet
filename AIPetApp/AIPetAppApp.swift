import SwiftUI
import SwiftData
import UserNotifications
import UIKit

/// UIKit AppDelegate：负责 APNs 推送注册与回调
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("请求推送权限失败: \(error)")
            }

            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        AuthService.shared.updatePushDeviceToken(tokenString)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("注册远程推送失败: \(error)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        NotificationCenter.default.post(name: .pushNotificationTapped, object: nil, userInfo: userInfo)
        completionHandler()
    }
}

@main
struct AIPetAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
        }
        .modelContainer(for: [Pet.self, PersonalityDNA.self, ChatMessage.self, Home.self])
    }
}
