import Foundation
import CoreGraphics

struct RuntimeDisplayDescriptor {
    let identifier: String
    let builtIn: Bool
    let mirrored: Bool
}

enum RuntimeSafetyFailure: LocalizedError {
    case accessibilityRequired
    var errorDescription: String? {
        "Autorise Spaces Dock dans Réglages Système → Confidentialité et sécurité → Accessibilité, puis réapplique le profil. L’opération a été arrêtée."
    }
}

func performAuthorizedRuntimeMutation<T>(isTrusted: () -> Bool, mutation: () throws -> T) throws -> T {
    guard isTrusted() else { throw RuntimeSafetyFailure.accessibilityRequired }
    return try mutation()
}

func runtimeTargetIsCurrent<T: Equatable>(_ target: T, desktopNumber: Int, desktops: [T]) -> Bool {
    guard desktopNumber > 0, desktopNumber <= desktops.count else { return false }
    return desktops[desktopNumber - 1] == target
}

// Pure boundaries for the live adapter; fixtures never access WindowServer.
func runtimeTopologyIssue(_ displays: [RuntimeDisplayDescriptor], separateSpaces: Bool) -> String? {
    guard !displays.isEmpty else { return "Aucun écran disponible. Réessaie après sa connexion." }
    guard displays.count <= 2 else {
        return "Cette version accepte l’écran intégré seul ou avec un seul écran externe. Débranche les écrans supplémentaires avant d’appliquer le profil."
    }
    guard displays.filter({ $0.builtIn }).count == 1 else {
        return "L’écran intégré doit être actif. Ouvre le MacBook ; le mode capot fermé et les Mac sans écran intégré ne sont pas pris en charge."
    }
    guard !displays.contains(where: { $0.mirrored }) else {
        return "La recopie d’écran n’est pas prise en charge. Utilise les écrans en mode étendu avant d’appliquer le profil."
    }
    guard !displays.contains(where: { $0.identifier.isEmpty }),
          Set(displays.map(\.identifier)).count == displays.count else {
        return "Les écrans ne peuvent pas être identifiés sans ambiguïté. Reconnecte l’écran externe, puis réessaie."
    }
    guard displays.count == 1 || separateSpaces else {
        return "Active « Les écrans disposent d’espaces distincts » dans Réglages Système → Bureau et Dock, puis déconnecte et reconnecte ta session."
    }
    return nil
}

func windowPlacementIsVerified(spaceIDs: [UInt64], targetSpace: UInt64, frame: CGRect?,
                               targetDisplay: CGRect) -> Bool {
    // A setter's return value is not evidence of the final frame: an app may
    // acknowledge without moving, or move after the AX reply times out.
    guard spaceIDs.contains(targetSpace), let frame,
          frame.width > 0, frame.height > 0,
          frame.minX.isFinite, frame.minY.isFinite,
          frame.width.isFinite, frame.height.isFinite else { return false }
    return targetDisplay.contains(CGPoint(x: frame.midX, y: frame.midY))
}
