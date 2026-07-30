import Foundation

/// A validated Google Apps Script web-app deployment endpoint.
public struct GoogleAppsScriptEndpoint: Hashable, Sendable {
    public let deploymentID: String

    let url: URL

    public init(deploymentID: String) throws {
        guard !deploymentID.isEmpty,
              deploymentID.unicodeScalars.allSatisfy(Self.isAllowedDeploymentIDScalar) else {
            throw TranslationFailure.invalidGoogleAppsScriptDeploymentID
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "script.google.com"
        components.path = "/macros/s/\(deploymentID)/exec"
        guard let url = components.url else {
            throw TranslationFailure.invalidGoogleAppsScriptDeploymentID
        }

        self.deploymentID = deploymentID
        self.url = url
    }

    private static func isAllowedDeploymentIDScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}
