# 검증 기록

최신 검증일: 2026-10-04 (Asia/Seoul)

## Xcode 프로젝트와 macOS 26·Swift 6 전환

`CodexMaestro.xcodeproj`를 추가했다. 앱, Core 정적 라이브러리, Probe와 두 XCTest 타깃은 SwiftPM과 소스를 공유한다. 세 공유 scheme은 일반 실행·테스트·archive, 데모 실행, Probe 실행을 구분한다. `project.yml`에서 모든 타깃의 최소 macOS 버전은 `26.0`, Swift 언어 모드는 `6.0`으로 설정했다. `Package.swift`와 앱 Info.plist도 macOS 26을 지정한다. SwiftPM tools 최소 버전은 6.2다.

검증 환경은 Apple Silicon Mac mini, macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4, XcodeGen 2.46.0이다. macOS 26은 배포 대상이며 이번 실행 환경이 아니다.

| 검증 | 결과 | 근거 |
|---|---|---|
| SwiftPM XCTest | Core 46개 + 앱 73개, **119개 통과**, 실패 0개 | `evidence/swift6-tests.log` |
| Xcode XCTest | 동일한 **119개 통과**, 실패·생략 0개 | `evidence/xcode-tests.log`, `.build/XcodeSwift6Tests-final.xcresult` |
| Xcode Release archive | 통과, arm64·x86_64의 Mach-O 최소 버전 `26.0` | `evidence/xcode-archive.log`, `.build/CodexMaestro-macOS26.xcarchive` |
| SwiftPM Release 패키징 | 통과, `dist/Codex Maestro.app` 갱신 | `evidence/swift6-package.log` |
| 두 앱의 strict ad-hoc 서명 | 종료값 0 | `evidence/xcode-artifact.json` |
| 프로젝트 재생성 | 프로젝트 파일과 3개 공유 scheme을 포함한 5개 파일의 SHA-256 유지 | `evidence/xcode-generation-reproducibility.json` |
| 현재 소스·설정·리소스 | 71개 파일의 manifest와 두 바이너리의 SHA-256 기록 | `evidence/xcode-artifact.json` |
| 읽기 전용 실제 IPC | 프로젝트 31개·로컬 세션 608개·live snapshot 13개·최근 대화 30개, 종료값 0 | `evidence/swift6-live-probe.log` |

Xcode에서 프로젝트를 다시 열고 `CodexMaestro` scheme, `My Mac` 실행 대상, 앱 타깃의 최소 배포 버전 `26.0`과 `Swift Language Version: Swift 6`을 직접 확인했다. 현재 프로젝트는 열어 둔 상태다. 언어 모드 화면과 AX 기록은 `evidence/xcode-swift6-settings.png` 및 `evidence/xcode-open-ui-ax.log`에 저장했다. 다섯 타깃의 실제 빌드 설정은 `evidence/xcode-all-target-settings.json`에 기록했다.

XCTest 통과 후 앱 카테고리를 `public.app-category.developer-tools`로 추가했다. 이 메타데이터 변경은 두 Release 패키지에 다시 반영했다. 테스트한 Swift 소스는 이후 바꾸지 않았다. 최종 archive의 App Category 미지정 경고는 없어졌다.

Xcode의 앱 테스트 호스트는 `--demo`로 실행한다. Probe는 현재 카탈로그를 조회하고 상태를 구독하며 프롬프트를 보내지 않는다. 수량은 조회 시점의 값이다. XCTest의 IPC 송신 계약은 기존 격리된 Unix 소켓 서버 검사로 확인한다. 실제 업무 세션에 대한 전송 E2E를 이번 조회로 주장하지 않는다.

Swift 6 전환에서 `DesktopBridge`의 응답 continuation은 `[String: Any]` 대신 `Data`를 전달한다. 응답 딕셔너리는 MainActor에서 다시 만든다. 백그라운드 프레임 디코더는 기존 JSON 검증을 유지하고 검증한 메시지 묶음의 소유권을 `sending`으로 MainActor에 이전한다. 새 `testMalformedFrameRejectsAnOtherwiseValidBatch`는 유효한 프레임 뒤에 비객체 JSON 또는 크기 0 프레임이 있어도 전체 묶음을 거부하는지 확인한다. 새로운 `@unchecked Sendable` 우회는 추가하지 않았다.

첫 네이티브 빌드는 `main.swift`의 `@main` 충돌로 실패했다. Probe 타깃에 `-parse-as-library`를 지정했다. Swift 6로 다시 빌드할 때 XcodeGen의 자동 Objective-C 헤더 복사 단계가 sandbox에서 실패했다. Swift 소비자만 있는 Core에 `SWIFT_INSTALL_OBJC_HEADER=NO`를 지정해 해당 단계를 생성하지 않도록 했다. User Script Sandboxing은 활성 상태로 유지한다. 앱의 기존 로컬 DB·소켓 접근을 위한 App Sandbox 비활성 설정은 그대로 적용했다.

실패 근거는 `evidence/xcode-tests-attempt1.log`, `evidence/xcode-tests-swift6-attempt1.log`와 `evidence/swift6-*-attempt*.log`에 보존했다. `xcode-tests-macos14-swift5.log`, `xcode-archive-macos14-swift5.log`, `swift6-tests-intermediate.log`는 전환 도중의 이전 결과다. 현재 산출물의 근거로 사용하지 않는다. Xcode 테스트 호스트 로그에는 macOS의 `com.apple.linkd.autoShortcut` 연결 메시지가 있으나 XCTest 실패와 result bundle의 runtime warning은 0개다. Archive의 App Intents metadata 생략 안내는 AppIntents 의존성이 없는 앱에서 발생한다.

이 검증은 macOS 26의 실제 실행, Intel의 실제 실행, 전체 UI 회귀·VoiceOver 탐색, 실제 프롬프트 전송 완료, Developer ID 서명·공증과 외부 배포를 포함하지 않는다. 기존 UI 확인 기록은 아래의 해당 시점에 한정한다.

아래는 2026-10-03의 이전 구현과 실행 시점에 대한 기록이다. 이전 manifest와 바이너리 해시는 현재 Xcode·Swift 6 산출물에 적용하지 않는다.

## 이전 단순화 적용 검증

단순화 후 **118개 테스트가 통과**했다. Core 45개와 앱 73개이며 실패는 없다. `evidence/cleanup-tests.log`에 전체 결과를 기록했다. Release 빌드·패키징은 `evidence/cleanup-package.log`, strict ad-hoc 서명과 50개 파일의 소스 manifest는 `evidence/cleanup-artifact.json`에서 확인한다. 별도 팀원이 현재 소스와 바이너리 해시를 다시 계산해 일치를 확인했다.

Swift 소스 146줄과 테스트 37줄을 줄여 총 183줄이 감소했다. 적용 전후 파일별 줄 수와 해시는 `evidence/cleanup-line-counts.json`에 기록했다. 이전 123개에서 빠진 5개는 삭제한 점 기반 대상 판정 테스트 4개와 typed 검사에 합친 이웃 어댑터 테스트 1개다. 저장 실패 복구·초안 충돌·표시 범위·무전송과 드래그 관찰 회귀는 유지했다. 이전 `prepareHandoff` 테스트는 현재 `prepareConnectionAction` 계약으로 옮겼다. `Models.swift`, `ContextTopologyLoader.swift`, `DesktopBridge.swift`는 이전 manifest와 바이트 단위로 같다.

최종 패키지의 네이티브 데모에서 프로젝트 더블 클릭, 일반 드래그의 다음 작업 선택·취소, 연결 아이콘의 공통 요청창과 전달 초안 준비를 확인했다. 전달 초안은 도착 세션 WATCH의 편집기에 표시됐고 세 프로젝트를 계속 표시했다. 근거는 `evidence/cleanup-ui-ax.log`와 `evidence/cleanup-handoff-prepared.png`다. 실제 Codex에 전송하지 않았다.

일반 앱에서는 실제 프로젝트의 9개 세션·14,290개 항목 지도를 열었다. 확인 시점의 전체 카탈로그는 607개 세션, 열린 세션은 11개였다. 최초 실행 화면에서는 0개가 보였고 이후 조회에서 11개로 바뀌었다. `evidence/cleanup-normal-ui-ax.log`는 이후 상태를 기록한다. 상태 수신 지연의 원인은 이번 변경에서 확인하거나 수정하지 않았다. 일반 앱의 기존 자동 저장은 수행될 수 있다. 실제 업무 세션에는 검증용 연결이나 요청을 만들지 않았다.

[단순화 적용·변경 후 검토·검증 범위](CLEANUP.md)에 상세 근거를 기록한다. Astra의 변경 후 읽기 전용 검토에는 자체 수정한 토폴로지 파일을 독립 검토로 포함하지 않았다. 검토한 저장소·연결창·테스트 이전에는 차단 결함이 없었다. 실제 모델 응답, 실제 스킬 실행, 새 FPS 수치와 외부 배포는 검증하지 않았다. 아래는 단순화 이전 소스와 실행 시점의 기록이다.

## 이전 컨텍스트 지도와 아이템 겹치기 검증

최종 소스에서 **123개 테스트가 통과**했다. Core 45개와 앱 78개이며 실패는 없다. 전체 로그는 `evidence/context-overlap-verified-current-tests.log`이다. Release 빌드, 앱 패키징과 strict ad-hoc 서명 검증은 `evidence/context-overlap-verified-current-package.log`에서 통과했다. 최종 바이너리 SHA-256은 `f38c02276b4bdd41cbea46f0cdbde03705ae88ec24c871ae0dccef80a17a49c8`이다. 소스 50개 파일의 해시와 산출물 정보는 `evidence/context-overlap-verified-current-artifact.json`에 기록했다. 검토자는 전체 manifest와 실행 파일을 다시 계산해 일치를 확인했다.

프로젝트 헤더, 사이드바 프로젝트, 세션 카드와 세션 목록의 더블 클릭은 해당 범위의 저장된 컨텍스트 지도를 연다. 프로젝트 조회는 필터와 카드 접힘에 관계없이 보관된 구성원도 포함한다. 기록 종류, 대화, 지침, 툴 호출·결과, 스킬·플러그인·파일 참조, 사용량과 압축 기록을 탐색한다. 현재 디스크의 지침과 Maestro의 연결·요청 설정은 별도 출처로 구분한다. 큰 본문은 선택할 때 다시 읽으며 긴 본문도 페이지 이동으로 확인할 수 있다. 현재 모델에 전달된 입력 전체를 복원한다고 주장하지 않는다.

패키징한 앱의 네이티브 데모에서 다음을 확인했다. 실제 Codex 세션에는 요청을 입력하거나 전송하지 않았다.

- 사이드바와 캔버스의 프로젝트 더블 클릭은 3개 세션과 연결 자료가 있는 지도를 열었다. 세션 카드 더블 클릭은 해당 세션 지도로 전환했다. 툴을 펼친 뒤 호출·결과와 선택한 결과 본문을 확인했다.
- 프로젝트의 툴 최적화 요청은 담당이 미지정이면 초안 준비가 비활성 상태였다. DESIGN을 지정하고 편집한 요청을 준비하면 그 세션의 입력창으로 이동했으며 전송 대기 상태로 남았다.
- Command 키 없이 아이템 자체를 드래그했다. 프로젝트→프로젝트, 프로젝트→세션, 세션→프로젝트, 세션→세션의 네 조합 모두 `다음 작업` 선택창을 열었다. 참고·전달·검토·직접 요청을 표시했다.
- 작업 선택 전 취소하면 원래 배치로 돌아왔다. 선택 전 작업공간 보존과 실패 시 복구는 별도의 상태·저장소 회귀 검사에서도 확인했다.
- 세션 겹치기에서 검토를 고르면 공통 요청 창으로 전환했다. 요청을 편집하고 초안을 준비하면 MODELS의 입력창에 표시했으며 다른 프로젝트도 유지했다. 자동으로 전송하지 않았다.
- 빈 영역으로 프로젝트와 세션을 옮겼다. 카드와 소속선·관계선이 이동하는 것을 화면에서 확인했다.

데모 근거는 `evidence/context-overlap-final-ui-ax.log`, `context-project-final.png`, `context-session-final.png`, `context-tool-final.png`, `context-overlap-choice-final.png`, `context-empty-drop-final.png`이다. 이 화면과 조작 로그는 최종 대형 기록 스캐너, 파일 위치 접미사 보완, 종류별 수량 보완과 탐색 순서 변경 이전에 캡처했다. 더블 클릭·겹치기·공통 요청·담당·초안·취소의 동작은 이후 변경하지 않았다. 최종 소스의 표시 수량과 실제 기록 조회는 아래의 별도 근거로 확인했다.

실제 CodexMaestro 프로젝트를 최종 `MaestroProbe --project-context`로 읽었다. **9개 세션, 9개 출처, 11,342개 기록, 100,414,918바이트**를 읽었으며 출처 9개 모두 complete, 보고된 읽기 오류 0개였다. 지도는 12,406개 노드와 15,255개 관계를 생성했다. 관찰된 툴은 31개 묶음이며 호출과 결과가 각각 1,430개였다. 실제 telemetry 3,115개와 카탈로그 누적 사용량 9개를 별도 출처로 표시했다. 이 프로젝트의 보관된 구성원은 이 시점에 0개였으며, 보관된 구성원의 포함·경로 경계는 독립 카탈로그 fixture로 확인했다.

실제 프로젝트 읽기의 wall time은 **3.14초**, 최대 RSS는 **539,787,264바이트**였다. 로그는 `evidence/context-project-verified-current-probe.log`이다. 이는 해당 시점 자료와 한 번의 로더 실행 측정이며 UI 렌더링 FPS나 임의 크기 프로젝트의 응답성 수치가 아니다. 이전 참조 정규식 실행은 ICU에서 지연돼 종료값 130으로 중단했다. 성공한 RED나 로드로 간주하지 않는다. 스택 표본은 `evidence/context-read-performance-before.sample.txt`에 있다. 선형 UTF-8 스캔으로 바꾼 뒤 1 MB가 넘는 경로 중심 출력에서도 전체 지연 본문과 공백 있는 스킬 경로, 파일 위치 접미사, 플러그인 URI를 유지하는 회귀 검사가 통과했다.

연결 문구 변경 전의 일반 앱에서 실제 프로젝트 더블 클릭으로 9개 세션·12,436개 항목 지도를 확인했다. 선택한 현재 세션의 첫 페이지에 기록 묶음이 나타났고 호출 768개·결과 767개로 표시했다. 근거는 `evidence/context-actual-verified-current-ui-ax.log`이다. 연결 문구를 포함한 최종 Release 앱에서도 같은 프로젝트를 더블 클릭해 9개 세션·12,822개 항목 지도를 확인했다. 최종 근거는 `evidence/context-final-caption-ui-ax.log`이다. 실행 중인 기록은 계속 늘어나므로 CLI 집계와 화면의 시점별 수량을 동일한 스냅샷으로 간주하지 않는다. 최종 수량 보완 전의 실제 툴 펼치기·전체 본문 조회는 `evidence/context-actual-current-ui-ax.log`에 별도 기록했다.

기존 IPC 경로의 실제 읽기 전용 probe는 프로젝트 31개, 보관되지 않은 세션 607개와 live snapshot 11개를 받았다. 근거는 `evidence/context-verified-live-ipc-probe.log`이다. CLI 상태 스트림 수신은 GUI 표시나 실제 프롬프트 전송 완료와 별도의 검증이다. 일반 앱은 기존 자동 저장을 수행하므로 이 실행 전체가 Maestro 작업공간 파일을 변경하지 않는다고 주장하지 않는다. 컨텍스트 조회가 연결·위치·초안을 저장하지 않는 조건은 상태·저장소 회귀 검사와 소스에서 확인했다.

일반 앱의 초기 표시에서는 열린 세션이 0개였으나 이후 11개로 바뀌었다. 최종 Release 앱을 실행한 직접 CUA 관찰도 최초에는 0개를 표시했다. 다음 조회부터 11개로 표시했으며, `evidence/context-final-caption-ui-ax.log`에는 이 회복된 상태와 실행 2개를 기록했다. 초기 수신 지연의 원인은 확인하지 못했다. footer는 연결 성공의 범위를 나타내도록 `실시간`에서 `Codex 연결`로 바꿨다. 이 문구 변경은 상태 스트림 수신 지연을 수정했다는 근거가 아니다.

[현재 동작과 자료 범위](CONTEXT-TOPOLOGY.md), [독립 검토](CONTEXT-OVERLAP-REVIEW.md)에 세부 판단을 기록했다. 실제 업무 세션의 최적화 실행·스킬 호출·응답 완료, 현재 모델 입력 전체, 전체 VoiceOver 탐색, Intel 실행, 공증·외부 배포는 검증하지 않았다. 아래 결과는 이전 소스와 실행 시점의 기록이다.

## 이전 작업 흐름 및 연결 검증

최종 소스에서 **100개 테스트가 통과**했다. Core 34개와 앱 66개이며 실패는 없다. 전체 로그는 `evidence/simple-flow-validated-tests.log`이다. Release 앱 패키징과 strict ad-hoc 서명 검증은 `evidence/simple-flow-validated-package.log`에서 통과했다. 바이너리 및 소스 해시, 일반 실행 전후 작업공간 비교는 `evidence/simple-flow-artifact-metadata.json`에 기록했다.

화면은 작업 흐름, 세션 제목과 상태, 선택한 세션의 대화 및 요청을 중심으로 정리했다. 모델·추론·경로·ID는 정보에 접었다. 저장 기록과 실시간 세션을 같은 상태 표기로 합치지 않는다. 연결창은 요청 내용, 담당, 참고 대상으로 구성하며 전체 생성 내용은 접힌 보낼 내용에서 확인한다. 스킬 선택기는 제거했고 수신 세션이 사용 가능한 적합한 스킬을 고르도록 생성 프롬프트에 지시한다.

네이티브 데모에서 다음을 확인했다. 실제 세션에는 전송하지 않았고 데모 변경은 메모리에만 저장했다.

- 세션→세션은 연결 드래그 모드로 생성했다. 검토 작업의 담당은 도착 세션 MODELS였다. 표시한 초안이 MODELS의 입력창에 들어왔으며 세 프로젝트를 계속 표시했다.
- 프로젝트→프로젝트, 프로젝트→세션, 세션→프로젝트는 연결 아이콘과 대상 클릭으로 생성했다. 프로젝트 실행은 담당을 지정하기 전까지 초안 준비가 비활성 상태였다. 프로젝트 전달에는 WATCH를 직접 지정해 그 세션의 초안을 준비했다.
- 설정을 닫은 뒤 생성한 연결 네 개와 원래 연결 세 개가 관리자에 남았다. 저장된 요청을 관리자에서 다시 열어 준비하면 중첩 창 둘을 닫고 담당 세션으로 돌아왔다.
- MODELS에 기존 초안이 있으면 다른 요청의 준비를 중단했다. 창에 충돌 오류를 표시했다. 원래 초안은 저장소 회귀 검사에서도 보존됐다.
- 연결 모드를 끈 일반 드래그는 위치를 바꿨으며 요청창을 열지 않았다. 작은 수직 이동 뒤 긴 연결이 WATCH에 가려지는 결함을 발견해 수정했다. 수정 후 같은 네이티브 조작에서 연결선이 WATCH 위로 지나가는 것을 확인했다.

위 근거는 `evidence/simple-flow-ui-ax.log`, `simple-flow-request-final.png`, `simple-flow-project-recipient-final.png`, `simple-flow-continuation-final.png`, `simple-flow-manager-final.png`, `simple-flow-conflict-final.png`에 있다. 마지막 작은 이동의 수정 화면은 `simple-flow-small-drag-final.png` 및 `simple-flow-main-final.png`이다. 작업 요청 및 담당 화면은 마지막 기하 수정 이전의 소스에서 캡처했다. 이후 변경은 연결 경로의 허용 수직 차이와 회귀 검사에 한정되며 요청·수신·준비 동작은 바뀌지 않았다.

긴 같은 행 회귀 검사는 한쪽 세션의 수평 이동 ±20pt와 수직 이동 ±12/±18pt, 양방향 연결의 32개 조합을 검사한다. 각 조합의 999개 곡선 지점은 WATCH와 세 프로젝트 헤더를 피한다. 이 결과는 해당 기본 배치와 작은 이동의 검증이며 임의의 밀집 배치 전체에 대한 장애물 회피 보장은 아니다. 601개 세션의 포인터 관찰 회귀 검사도 유지했다. FPS나 체감 성능의 새로운 전후 수치를 측정하지 않았다.

일반 Codex 모드로 다시 열어 실제 활성 세션을 선택했다. `evidence/simple-flow-live-probe.log`에서는 프로젝트 31개, 보관되지 않은 로컬 세션 607개, live snapshot 11개를 읽었다. 일반 UI는 열린 세션 11개와 전체 607개, 실시간 상태 및 저장 기록의 구분을 표시했다. 수량은 해당 시점의 값이다. `evidence/simple-flow-normal-ax.log`에 실제 UI 상태를 기록했다. 일반 실행 전후 작업공간 파일의 SHA-256은 달랐다. 일반 앱의 자동 저장이 수행되므로 이 실행을 파일 변경이 없는 조회로 주장하지 않는다. 실제 작업공간에서 검증용 연결을 만들거나 요청을 입력·전송하지 않았다.

[연결 동작](COMMAND-CONNECTIONS.md), [독립 Astra 검토](COMMAND-CONNECTIONS-REVIEW.md)에 판단과 한계를 기록한다. CUA native drag는 modifier 유지 기능을 제공하지 않아 물리 Command 키를 누른 드래그 전체를 검증하지 않았다. 접근성 연결 모드는 같은 드롭·설정 경로를 사용한다. 실제 모델 응답 및 스킬 호출 완료까지의 전송 E2E, 외부 배포·공증, 전체 VoiceOver 탐색은 아직 검증하지 않았다. 아래 결과는 이전 소스와 실행 시점의 기록이다.

## 이전 프로젝트·세션 혼합 연결 검증

최종 소스에서 **71개 테스트가 통과**했다. Core 29개와 앱 42개이며 실패는 없다. `evidence/mixed-corrected-tests.log`에 전체 결과를 기록했다. 수정 후 Release 앱과 strict ad-hoc 서명 검증은 `evidence/mixed-corrected-package.log` 및 `evidence/mixed-artifact-metadata.log`에서 확인했다.

네이티브 데모에서 네 조합의 생성, 연결 유형 변경과 메모 유지, 방향 필터, 삭제, 양쪽 상세의 관계 표시와 이동을 확인했다. Astra가 찾은 같은 열의 긴 혼합 연결선 결함은 수정 후 양방향 곡선과 화살표를 화면에서 확인했다. 실제 읽기 전용 조회는 프로젝트 31개, 로컬 세션 607개, live snapshot 11개였다. 조회 수는 해당 시점의 값이다.

[혼합 연결 보고서](MIXED-CONNECTIONS.md), [Astra 구현 검토](ASTRA-MIXED-REVIEW.md), [Astra 기능 기획](ASTRA-FEATURE-PLAN.md)에 구현·검증·제안을 구분해 기록했다. 아래 결과는 이전 소스와 실행 시점의 기록이다.

## 이전 디자인 적용 검증

최종 소스에서 **52개 테스트가 통과**했다. Core23개와 앱29개이며 실패는 없다. 근거는 `evidence/design-final-tests.log`이다. Release 앱과 로컬 서명은 `evidence/design-final-package.log` 및 `evidence/design-artifact-metadata.log`에서 확인했다.

밝은·어두운 네이티브 화면, 연결 라벨 배치, 데모 연결·전달 초안, 전체606개 세션을 펼친 드래그를 확인했다. 마지막3개 CUA 드래그의 좌표 갱신2/1/1회 동안 배치 재계산은 각각0회였다. 이는 FPS 측정이 아니다. 실제 Codex 조회에서는 프로젝트31개, 로컬 세션606개, live snapshot11개를 확인했다.

[디자인 적용 보고서](DESIGN-APPLICATION.md), [Astra 디자인 재검토](ASTRA-DESIGN-REVIEW.md), `evidence/design-ui.log`에 상세 근거와 한계를 기록했다. 아래의 초기 빌드와 팀 작업 수치는 각 시점의 기록이다.

## 빌드와 테스트

| 구분 | 결과 | 근거 |
|---|---|---|
| Swift debug build | 통과 | `evidence/build.log` |
| Swift release build | 통과 | `evidence/package.log` |
| 앱 번들 생성 및 ad-hoc 서명 검증 | 통과 | `scripts/package-app.sh`, `evidence/package.log` |
| XCTest | 11개, 실패 0개 | `evidence/tests.log` |

테스트는 아래 경계를 검증합니다.

- UTF-8/한글/이모지가 포함된 IPC 프레임의 분할 수신 및 다중 프레임 수신.
- 0바이트/초과 크기/객체가 아닌 프레임 거부.
- 런타임 상태 스냅샷 및 activeFlags 패치의 실행/입력대기/대기 전환.
- 방향 있는 관계, 중복 및 자기 연결 거부, 작업공간 저장·재로드와 `0600` 권한.
- 손상된 JSON의 읽기 실패 시 기존 데이터 유지.
- 프로젝트의 명시적 소속 우선 적용, 경로 경계 기반 fallback, 보관된 세션 제외 및 DB 내용 불변.
- 대화 텍스트의 시간순 표시, 도구 메시지 제외, 바인딩된 SQL 파라미터와 메시지 제한.
- 프롬프트 원문 보존, 대상 세션 일치, 모델 및 권한 override 없음.
- 실제 Unix 소켓 fixture에서 initialize → 상태 구독 → 소유자 탐색 → 지정 소유자 전송 → 수락 turn ID 수신.
- 소유자가 없을 때 전송하지 않음, 연결되지 않은 상태에서 전송 거부.
- desktop `patches` 프레임을 받은 뒤 상태가 입력 대기로 변경됨.

## 실제 설치된 Codex와 연동

대상 데스크톱: `26.930.31428 (12913)` / 번들 CLI: `0.160.0`.

`MaestroProbe`와 앱 실행 화면에서 다음을 확인했습니다.

- 로컬 프로젝트 **31개**, 보관되지 않은 세션 **601개** 조회.
- 열린 세션 **4개**의 실제 IPC 스냅샷 수신.
- 이 개발 대화는 실행 중, 나머지 열린 세션은 대기 중으로 표시.
- 실제 모델 이름과 추론 수준, 프로젝트 경로 및 저장된 사용자/에이전트 메시지 조회.
- 앱 종료 후 재실행 시 IPC 연결을 다시 수립.

이는 해당 시점의 관찰값입니다. 프로젝트/세션 수는 이후 달라질 수 있습니다. 저장된 세션의 수정 시간을 실행 상태로 간주하지 않았습니다. IPC 상태를 받지 못한 세션은 `상태 미확인`으로 표시합니다.

읽기 전용 진단 로그: `evidence/live-probe.log`.

## 실제 macOS UI 검증

Computer Use로 패키징한 `Codex Maestro.app`을 직접 조작했습니다.

- 실제 데이터의 프로젝트 목록, `연결된 세션` 필터 및 토폴로지 표시.
- 실제 세션 선택 후 제목, 상태, 모델, 추론 수준, 경로, 저장된 대화 확인.
- 데모 모드에서 세션 연결 아이콘 → 도착 세션 선택 → 메모 입력 → 연결 생성. 관계 수 3 → 4 증가 확인.
- 연결 상세에서 방향, 연결 목적, 메모, 대상 세션 확인.
- 전달 초안 준비 후 받는 세션으로 이동하며 원본 세션 출처·메모·최근 응답이 입력창에 들어오는 것을 확인.
- 데모 전송 버튼 → 실제 전송 없음 안내 및 활동 기록 확인.
- 검색어 `브리지` 입력 시 해당 세션만 남고, 검색어 제거 후 전체 그래프 복원.
- 캔버스 노드 드래그 후 카드와 연결 경로가 함께 이동하는 것을 시각적으로 확인.
- 기본 1480 × 920 창에서 3개 프로젝트 열과 상세 패널의 배치를 확인.

데모 연결과 프롬프트는 메모리에만 존재하며 실제 작업공간 파일이나 Codex 세션에 기록하지 않았습니다.

## 아직 검증하지 않은 범위

- **실제 업무 세션으로 프롬프트를 보내 모델의 다음 응답이 완료되는 전송 E2E.** 전송 대상·프롬프트·소유자 라우팅·수락 응답은 격리된 소켓 fixture에서 검증했습니다.
- 원격 호스트 / ChatGPT 클라우드 세션: 현재 제품 범위에 포함하지 않았습니다.
- 다른 Codex 데스크톱 버전과 향후 내부 프로토콜 변경에 대한 호환성.
- macOS 14부터의 모든 OS 버전에 대한 실행 검증, Intel 바이너리 실행 검증.
- Developer ID 서명, 공증, 배포 및 자동 업데이트.

## 멀티 세션 팀 작업 검증 (2026-10-03 추가)

구현 역할은 세션·프로젝트 연결, Codex 연동, 성능 회귀 검증으로 나눴습니다. 리더는 드래그 상태 분리와 UI 통합을 담당했습니다. 구현 후 별도 Astra 모델 세션이 코드와 증거를 검토합니다. 검토 결과는 `docs/ASTRA-REVIEW.md`에 기록합니다.

### 자동 검증

`evidence/team-tests.log`의 초기 통합 검증에서는 34개 테스트가 통과했습니다. Astra 지적을 수정한 최종 소스의 `evidence/astra-fix-tests.log`에서는 **40개 테스트가 통과**했습니다. Core 테스트 23개와 앱 테스트 17개이며 실패는 없습니다. 다음 경계를 추가로 검증합니다.

- 이전 작업공간 JSON 읽기, 프로젝트·세션 연결 생성·편집, UUID 유지, 중복과 자기 연결 거부.
- 연결 저장 실패 시 메모리 변경 복원. 손상된 작업공간 파일을 덮어쓰지 않음.
- 전달 초안 저장 실패 시 기존 초안과 선택 상태 유지. 성공 시 기존 초안을 보존하여 컨텍스트 추가.
- 601개 세션의 소속·정렬·접기·펼치기·검색. 드래그 상태 갱신이 배치 관찰을 무효화하지 않음.
- 순서가 있는 상태 배열의 삽입·교체·삭제. 잘못된 상태 패치의 부분 적용 방지와 새 스냅샷 요청.
- 여러 프로젝트 루트가 있을 때 실제 경로와 일치한 루트만 비교. 명시적 프로젝트 소속 우선 유지.

### 실제 macOS UI

Release 앱의 `--performance-catalog` 모드에서 로컬 카탈로그 **606개 세션**을 펼쳤습니다. 이 모드는 실제 저장된 세션의 제목과 소속을 사용하지만, 연결·배치·초안 변경은 메모리에만 저장합니다. IPC 구독과 자동 새로고침은 실행하지 않습니다.

`evidence/performance-ui.log`에는 완료한 드래그 3회의 좌표 갱신 횟수 **33회, 14회, 18회**가 기록되어 있습니다. 각 드래그의 이동 구간에서 토폴로지 배치 재계산은 **0회**였습니다. 드롭 후 위치를 반영하는 배치 계산은 이 측정 구간에 포함하지 않습니다. 이 기록은 FPS나 이전 빌드 대비 속도 배수를 측정하지 않습니다.

Computer Use로 다음 동작을 확인했습니다.

- 프로젝트 연결 생성: 출발·도착 프로젝트, 선행 작업 관계와 메모 저장.
- 같은 연결의 목적을 검토 요청으로 바꾸고 메모 수정.
- 검증용 프로젝트 연결 삭제 후 빈 목록 표시.
- 서로 다른 프로젝트의 세션 연결 생성.
- 전달 초안 준비 후 받는 세션으로 이동. 초안에 출발 세션의 제목·URL·메모·컨텍스트 표시.

실제 Codex 조회는 별도로 실행했습니다. `evidence/team-live-probe.log`에서 프로젝트 31개, 보관되지 않은 세션 605개, 열린 세션 6개의 실제 상태 스냅샷을 확인했습니다. 조회 시점이 다르므로 카탈로그 수는 UI 검증과 다릅니다.

실제 업무 세션에는 검증용 프롬프트를 전송하지 않았습니다. 기존 전송 E2E 제한과 내부 IPC 호환성 제한은 그대로 적용됩니다.

### Astra 검토에 따른 회귀 수정

- 세션을 전환하면 이전 세션의 대화와 오류를 즉시 지웁니다. 선택하지 않은 세션의 읽기는 현재 로딩 상태를 바꾸지 않습니다. 이전 읽기가 늦게 완료되거나 실패해도 새 세션의 로딩을 유지합니다. 네 가지 동시성 테스트가 `evidence/transcript-tests.log`에서 통과했습니다.
- 캔버스 연결 편집기는 현재 카탈로그에 있는 출발·도착 세션을 검증합니다. 중복 연결이나 저장 실패가 발생하면 편집기를 유지합니다. 연결 생성 성공 시에만 연결 선택 상태를 해제합니다.
- IPC 쓰기를 직렬 백그라운드 큐로 옮겼습니다. 소켓 데이터를 읽지 않는 피어가 있어도 메인 스레드가 대기하지 않습니다. 쓰기 기한 초과 또는 요청 시간 초과 시 연결을 종료합니다. 종료된 전송을 자동 재시도하지 않습니다.

`StalledPeerTests`는 초기화와 소유자 확인 이후 소켓을 읽지 않는 격리 피어를 사용합니다. 4 MiB 테스트 프롬프트로 송신 버퍼를 채웁니다. 수정 전 메인 스레드 확인 작업은 3.043462초 지연되어 테스트가 실패했습니다. 같은 테스트가 수정 후 통과했습니다. 확인 작업은 0.157278초에 실행됐고 연결 종료는 0.000117초가 걸렸습니다. 근거는 `evidence/connection-stalled-peer-attempt.log`와 `evidence/connection-stalled-peer-final.log`입니다. 이 측정은 소켓 대기 중 UI 응답 가능성을 확인하며 실제 Codex 응답 시간이나 캔버스 FPS를 측정하지 않습니다.

### 검토 반영 빌드와 마지막 UI 확인

`evidence/team-reviewed-package.log`에서 검토 수정 후 Release 빌드, 앱 번들 생성, 로컬 서명 검증이 통과했습니다. `evidence/reviewed-live-probe.log`에서 프로젝트 31개, 보관되지 않은 세션 608개, 실제 열린 세션의 상태 8개를 수신했습니다. 조회 대상 수는 시점에 따라 변합니다.

최종 Release 데모에서 `CodexMaestro → RunnersHeart` 프로젝트 연결선과 방향 화살표를 화면으로 확인했습니다. 같은 세션 연결을 중복 생성했을 때 편집기가 유지되고 `동일한 연결이 이미 있습니다.`가 표시되는 것도 확인했습니다. 인라인 오류를 표시한 편집기는 전역 오류 상태를 소비하여 취소 뒤 같은 오류 알림이 반복되지 않게 했습니다.

최종 UI 오류 상태 소비 수정 후 `evidence/final-package.log`에서 Release 빌드와 로컬 서명 검증이 통과했습니다. 실제 UI에서 중복 오류 확인 후 취소가 정상 창으로 돌아오고 오류 알림이 반복되지 않는 것을 확인했습니다. 앱은 일반 Codex 연결 모드의 전체 세션 화면으로 열어두었습니다. 마지막 화면에서는 카탈로그 608개 세션과 실시간 연결 8개를 표시했습니다. 관찰 기록은 `evidence/final-ui-observations.log`에 있습니다.
