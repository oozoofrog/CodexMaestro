#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [applications-directory]" >&2
    exit 2
fi

MAESTRO_INSTALL_DIR="${1:-/Applications}"
mkdir -p "$MAESTRO_INSTALL_DIR"
MAESTRO_INSTALL_DIR="$(cd "$MAESTRO_INSTALL_DIR" && pwd -P)"
if [[ ! -w "$MAESTRO_INSTALL_DIR" ]]; then
    echo "설치 폴더에 쓰기 권한이 없습니다: $MAESTRO_INSTALL_DIR" >&2
    exit 1
fi
MAESTRO_DESTINATION="$MAESTRO_INSTALL_DIR/Codex Maestro.app"
if [[ -L "$MAESTRO_DESTINATION" ]]; then
    echo "설치 대상이 심볼릭 링크입니다: $MAESTRO_DESTINATION" >&2
    exit 1
fi

./scripts/package-app.sh
MAESTRO_STAGE_DIR="$(mktemp -d "$MAESTRO_INSTALL_DIR/.CodexMaestro-install.XXXXXX")"
trap 'rm -rf "$MAESTRO_STAGE_DIR"' EXIT
MAESTRO_STAGED_APP="$MAESTRO_STAGE_DIR/Codex Maestro.app"
ditto "$PWD/dist/Codex Maestro.app" "$MAESTRO_STAGED_APP"
codesign --verify --strict "$MAESTRO_STAGED_APP"

swift -swift-version 6 - "$MAESTRO_STAGED_APP" "$MAESTRO_DESTINATION" <<'SWIFT'
import AppKit
import Foundation

let staged = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let expectedID = "com.oozoofrog.CodexMaestro"
let files = FileManager.default

do {
    guard Bundle(url: staged)?.bundleIdentifier == expectedID else {
        throw NSError(domain: "CodexMaestroInstaller", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "설치할 앱의 번들 ID가 올바르지 않습니다."])
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: expectedID)
    guard !running.contains(where: {
        $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL
    }) else {
        throw NSError(domain: "CodexMaestroInstaller", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "설치된 Codex Maestro를 종료한 뒤 다시 설치하세요."])
    }
    if files.fileExists(atPath: destination.path) {
        guard Bundle(url: destination)?.bundleIdentifier == expectedID else {
            throw NSError(domain: "CodexMaestroInstaller", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "설치 대상에 다른 앱 또는 파일이 있습니다: \(destination.path)"])
        }
        _ = try files.replaceItemAt(destination, withItemAt: staged,
                                    backupItemName: nil, options: .usingNewMetadataOnly)
    } else {
        try files.moveItem(at: staged, to: destination)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
SWIFT

codesign --verify --strict "$MAESTRO_DESTINATION"
echo "설치 완료: $MAESTRO_DESTINATION"
