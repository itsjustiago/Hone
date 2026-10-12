import Foundation
import UserNotifications

/// Notificações do sistema do Sleepy (paragem automática, avisos da tampa).
///
/// Só funciona dentro de uma app (`.app` com bundle id): sem isso — `swift test`,
/// binário solto — o `UNUserNotificationCenter.current()` crasha, por isso aí
/// tudo é no-op e o centro nem se toca.
///
/// É o delegate do centro: sem isso o macOS não mostra notificações com a app
/// ativa (e a Hone está quase sempre ativa quando o popover está aberto).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Recebe o identificador da ação carregada numa notificação (ponto de
    /// extensão: o "Mais 1 h" do lote D). Corre no main. Inclui o clique no
    /// corpo da notificação (`UNNotificationDefaultActionIdentifier`).
    var onAction: ((String) -> Void)?

    private static let askedKey = "notificationsAsked"
    private var configured = false

    private override init() { super.init() }

    /// Só dentro de uma app: `swift test` não tem bundle e o centro crasha.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Liga o delegate. Idempotente; chamar cedo, para uma ação tocada numa
    /// notificação antiga chegar a `onAction`. Não pede autorização.
    func activate() {
        guard Self.isAvailable, !configured else { return }
        configured = true
        UNUserNotificationCenter.current().delegate = self
    }

    /// Pede autorização (aviso + som) só da primeira vez que se liga o Sleepy.
    func requestAuthorizationIfNeeded() {
        guard Self.isAvailable else { return }
        activate()
        let defaults = SleepyDefaults.store
        guard !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(true, forKey: Self.askedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Sleepy: autorização das notificações falhou: \(error)") }
            else if !granted { NSLog("Sleepy: notificações recusadas — os avisos ficam só no painel") }
        }
    }

    /// Mostra já uma notificação. Sem autorização o sistema ignora-a em silêncio.
    func notify(_ body: String, title: String = "Sleepy") {
        guard Self.isAvailable else { return }
        activate()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Sleepy: notificação falhou: \(error)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        completionHandler()
    }
}
