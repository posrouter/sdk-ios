import Foundation
import UIKit

enum LocalRouteScanner {
    static func checkAcquirerInstalled(scheme: String) -> Bool {
        guard !scheme.isEmpty, let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
