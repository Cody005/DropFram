import Foundation

enum PythonRuntimeBootstrap {
    static func configure() {
        let bundleRoot = Bundle.main.bundleURL
        let pythonRoot = bundleRoot.appendingPathComponent("python", isDirectory: true)
        let libraryRoot = pythonRoot.appendingPathComponent("lib", isDirectory: true)
        let packageRoot = bundleRoot.appendingPathComponent("python-packages", isDirectory: true)
        let certificateBundle = packageRoot.appendingPathComponent("cacert.pem")

        guard
            let versionFolder = try? FileManager.default.contentsOfDirectory(
                atPath: libraryRoot.path
            ).first(where: { $0.hasPrefix("python3.") })
        else {
            return
        }

        let standardLibrary = libraryRoot.appendingPathComponent(
            versionFolder,
            isDirectory: true
        )
        let dynamicLibraries = standardLibrary.appendingPathComponent(
            "lib-dynload",
            isDirectory: true
        )
        let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("yt-dlp", isDirectory: true)

        if let cacheDirectory {
            try? FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            setenv("XDG_CACHE_HOME", cacheDirectory.path, 1)
        }

        setenv("PYTHONHOME", pythonRoot.path, 1)
        setenv(
            "PYTHONPATH",
            [
                packageRoot.path,
                standardLibrary.path,
                dynamicLibraries.path
            ].joined(separator: ":"),
            1
        )
        if FileManager.default.fileExists(atPath: certificateBundle.path) {
            setenv("SSL_CERT_FILE", certificateBundle.path, 1)
            setenv("REQUESTS_CA_BUNDLE", certificateBundle.path, 1)
        }
    }
}
