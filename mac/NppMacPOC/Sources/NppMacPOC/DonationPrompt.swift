import Foundation

/// Controla cuándo mostrar el botón "Apoyar el proyecto" en la toolbar:
/// aparece a los 7 días calendario del primer lanzamiento si nunca se
/// clickeó donar (desde toolbar o desde "Acerca de"), y desaparece para
/// siempre en cuanto se clickea una vez.
enum DonationPrompt {
    private static let firstLaunchKey = "donationPrompt.firstLaunchDate"
    private static let clickedKey = "donationPrompt.buttonClicked"
    private static let daysBeforeShowing = 7

    /// Se llama una vez en el arranque de la app (NppMacPOCApp.init). Si ya
    /// existe una fecha guardada, no la pisa — debe fijarse una sola vez.
    static func registerFirstLaunchIfNeeded() {
        guard UserDefaults.standard.object(forKey: firstLaunchKey) == nil else { return }
        UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
    }

    static var hasBeenClicked: Bool {
        UserDefaults.standard.bool(forKey: clickedKey)
    }

    /// Marca el flag como clickeado de forma permanente. Llamarlo desde
    /// cualquiera de los dos botones (toolbar y "Acerca de") oculta el
    /// botón de toolbar para siempre.
    static func markClicked() {
        UserDefaults.standard.set(true, forKey: clickedKey)
    }

    static var shouldShowInToolbar: Bool {
        guard !hasBeenClicked else { return false }
        guard let firstLaunch = UserDefaults.standard.object(forKey: firstLaunchKey) as? Date else {
            // No debería pasar si registerFirstLaunchIfNeeded() corrió en el
            // init, pero si falta la fecha no hay base para contar 7 días.
            return false
        }
        let days = Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        if days < 0 {
            // Reloj del sistema estaba adelantado al primer lanzamiento (batería CMOS
            // muerta, Mac restaurado sin NTP): sin este reset, el botón queda invisible
            // hasta años después de corregirse el reloj.
            UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
            return false
        }
        return days >= daysBeforeShowing
    }
}
