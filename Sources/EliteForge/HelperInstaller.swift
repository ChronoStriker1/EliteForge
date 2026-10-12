import Foundation

/// Installs the root helper from inside the app bundle using the standard
/// macOS administrator password prompt.
enum HelperInstaller {
    enum InstallError: LocalizedError {
        case missingResources
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: "The helper isn't inside this copy of the app. Build it with scripts/build-app.sh."
            case .failed(let message): message
            }
        }
    }

    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/com.eliteforge.helper") }
    static var bundledPlist: URL? { Bundle.main.url(forResource: "com.eliteforge.helper", withExtension: "plist") }
    static var installScript: URL? { Bundle.main.url(forResource: "install-helper", withExtension: "sh") }
    static var uninstallScript: URL? { Bundle.main.url(forResource: "uninstall-helper", withExtension: "sh") }

    static func install() throws {
        guard let script = installScript, let plist = bundledPlist,
              FileManager.default.isExecutableFile(atPath: bundledHelper.path) else { throw InstallError.missingResources }
        // The helper only accepts these exact binaries; the script records their code hashes.
        guard let app = Bundle.main.executableURL, let cli = Bundle.main.url(forResource: "forgectl", withExtension: nil) else { throw InstallError.missingResources }
        try runAsAdministrator([script.path, bundledHelper.path, plist.path, app.path, cli.path],
                               prompt: "EliteForge needs to install a helper so it can configure your controller over USB.")
    }

    static func uninstall() throws {
        guard let script = uninstallScript else { throw InstallError.missingResources }
        try runAsAdministrator([script.path], prompt: "EliteForge will remove its controller helper.")
    }

    private static func runAsAdministrator(_ arguments: [String], prompt: String) throws {
        let command = arguments.map(shellQuote).joined(separator: " ")
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw InstallError.failed("Couldn't prepare the installer.") }
        script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -128 { throw InstallError.failed("Installation was cancelled.") }
            throw InstallError.failed(error[NSAppleScript.errorMessage] as? String ?? "The helper couldn't be installed.")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
