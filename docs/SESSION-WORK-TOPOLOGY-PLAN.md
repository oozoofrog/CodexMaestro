# 세션 상세 작업 구조 토폴로지 기획

**현재 상세 지도는 기록 종류별 탐색을 제공한다. 사용자 요청부터 실행·위임·검증·결과까지 이어지는 작업 구조를 보려면 별도 모델과 화면이 필요하다.** 기존 기록 지도를 유지하고, 세션 진입 시 현재 요청의 작업 구조를 먼저 표시하는 방안을 제안한다.

이 문서는 2026-10-04에 실행 중인 로컬 세션 하나의 설치 앱, 소스와 저장 기록을 확인한 결과다. 기능 구현이나 재설치 결과를 주장하지 않는다. 기획 산출물은 [상세 구조 다이어그램](../design-previews/session-work-topology-plan.html)에서 탐색할 수 있다. 다이어그램은 제안하는 관계를 설명하며 실제 작업 화면의 스크린샷이 아니다.

## 1. 확인 대상과 근거

- 세션 표시 제목: **Codex 관리 도구 만들기**.
- 세션 ID: `01a100d8-585b-74c3-8d63-332de28dd73d`.
- 현재 요청: `현재 동작하는 세션하나의 상세 작업 구조 토폴로지 구현을 확인하고 기획해주세요`.
- 확인한 현재 turn: `01a1063c-4d61-70b0-a6ae-b0855389d48a`.
- 설치 앱: `/Applications/Codex Maestro.app`.
- 자료: 로컬 `state_5.sqlite`, 해당 세션의 rollout JSONL, 설치 앱의 접근성 트리와 화면, 현재 checkout의 소스.

18:28 KST에 연 상세 지도는 11,433개 항목을 표시했다. 이후 읽기 전용 `MaestroProbe --context` 조회에서는 11,456개 노드와 14,092개 관계를 만들었다. 출처 하나의 10,597개 기록, 101,965,570바이트를 읽었으며 확인 범위 오류는 없었다. 결과는 [범위 조회 로그](../evidence/session-work-topology-context-probe.log)에 있다.

18:37 KST의 별도 구조 검사에서는 파일 끝을 104,260,436바이트로 고정해 10,747개 레코드를 읽었다. 직접 식별한 turn ID는 28개였다. `task_started` 28개, `task_complete` 26개, `turn_aborted` 1개를 확인했다. 이 시점에 현재 turn의 종료 이벤트는 없었다. 호출 1,339개 중 결과가 연결된 호출은 1,338개였다. 나머지 하나는 검사 프로그램 자체의 실행 호출이었다. 호출 레코드의 `status: completed`만으로 결과 수신을 판단할 수 없다는 실제 사례다.

이 수량은 서로 다른 시점의 스냅샷이다. 현재 세션이 기록을 계속 추가하므로 수량 차이를 손상으로 해석하지 않는다. [구조 검사 JSON](../evidence/session-work-topology-record-audit.json)은 ID·타입·필드 이름·출처 위치만 보존한다. 대화 본문과 내부 reasoning 본문은 포함하지 않는다.

## 2. 현재 구현에서 가능한 작업

| 확인한 동작 | 소스와 실제 관찰 |
| --- | --- |
| 세션 범위 읽기 | `ContextTopologyLoader.load(session:)`이 선택한 세션의 저장 기록을 읽는다. |
| 기록 분류 | 대화, 지침, 도구 호출·결과, 사용량, 압축, 메타데이터, 파일·스킬·플러그인 참조를 구분한다. |
| 호출과 결과 연결 | 직접 기록된 `call_id`로 호출과 결과를 연결한다. 실제 화면에서 첫 `exec` 호출을 펼쳐 연결된 결과를 확인했다. |
| 큰 기록 탐색 | 페이지당 18개 항목을 표시한다. 선택한 본문을 지연 조회하며 12,000글자씩 표시한다. |
| 조회 결과 보호 | 다른 범위를 열거나 닫으면 이전 조회를 취소한다. generation과 범위를 검사해 늦은 결과를 거부한다. |
| 출처 확인 | 기록 위치와 fingerprint를 검증한다. 일부 읽기·기록 없음·오류를 구분한다. |
| 실시간 세션 상태 | IPC 상태가 세션 카드와 전역 상태에 반영된다. 상세 기록 지도는 열 때 만든 스냅샷이며 다시 읽기를 해야 갱신된다. |

화면에서 도구 호출 묶음을 펼치면 `exec`와 `js` 같은 도구 이름별 묶음과 오래된 개별 호출이 먼저 나타난다. 확인한 페이지의 첫 호출은 2026-10-03 08:19 UTC의 기록이었다. 현재 요청이나 현재 실행 위치를 먼저 보여주는 구조는 없다.

구현 연결은 Swift Intelligence의 semantic references로도 확인했다. `MaestroStore`가 로더를 호출하고 `ContextTopologyView`가 선택 본문을 읽는다. `DecisionWorkbenchStore`도 같은 로더를 사용하므로 새 작업 구조 모델을 도입할 때 기존 판단 입력의 계약을 보존해야 한다.

## 3. 우선 해결할 누락

### 카탈로그의 하위 세션 계약

실제 DB의 자식 세션 4개는 아래 형태를 사용한다.

```json
{"subagent":{"thread_spawn":{"parent_thread_id":"01a100d8-585b-74c3-8d63-332de28dd73d","agent_path":"/root/connections"}}}
```

현재 `CodexCatalog.swift:49`는 `source["subAgent"]`를 읽는다. 실제 `subagent`와 대소문자가 다르다. 따라서 이 저장 카탈로그에서 `parentID`를 복원하지 못한다. 로더에는 상위·하위 세션 관계를 추가하는 코드가 있지만 이번 단일 세션 지도에는 그 관계가 생성되지 않았다.

확인한 자식 경로는 `/root/connections`, `/root/codex_features`, `/root/performance_validation`, `/root/astra_review`다. 이것은 과거에 생성한 하위 세션의 존재를 확인한다. 네 하위 세션이 현재 요청에서 실행 중이라는 의미는 아니다. IPC의 `parentID`가 별도로 채워지는 경우도 있으므로 앱 전체의 모든 관계가 항상 누락된다고 일반화하지 않는다.

### 구조화된 내부 도구 실행

현재 turn의 `event_msg.item_completed.item`에서 `CommandExecution`과 `McpToolCall`을 확인했다. 명령 기록에는 `command`, `cwd`, `process_id`, `status`, `exit_code`, `duration`이 있다. MCP 기록에는 `server`, `tool`, `arguments`, `status`, `result`, `duration`이 있다. 현재 로더는 바깥의 `item_completed`를 메타데이터로 분류하며 내부 실행을 별도 작업 노드로 추출하지 않는다.

로더가 처리하는 직접 항목의 `commandExecution`·`mcpToolCall`과 실제 중첩 항목의 `CommandExecution`·`McpToolCall`도 다르다. 새 어댑터는 바깥 이벤트와 내부 항목을 함께 검사해야 한다. JavaScript 문자열에서 명령 이름을 찾는 방식보다 실제 구조화된 실행 기록을 우선한다.

### 작업과 기록의 관계

`ContextNode`에는 turn, 작업 단계, 상태, 시작·종료 시각이 없다. `ContextEdge.relation`은 문자열이며 소속·호출 결과·작업 의존성의 타입을 강제하지 않는다. `task_started`·`task_complete`·`turn_aborted`도 작업 수명주기로 모델링하지 않는다. 시간순 배열만으로 단계 의존성이나 병렬 실행을 표현해서는 안 된다.

## 4. 사용자가 먼저 볼 화면

세션 상세 화면에는 **작업 구조 / 기록 지도** 두 보기를 둔다. 작업 구조는 최신 요청의 turn을 기본 범위로 사용한다. 과거 turn 선택과 전체 기록 지도는 같은 위치에서 접근한다.

| 영역 | 표시할 내용 |
| --- | --- |
| 상단 | 현재 요청 원문, 선택한 turn, 실시간 세션 상태, 기록 확인 시각, 기록 갱신 상태 |
| 중앙 | 요청 → turn → 실행·결과의 연결. 관련 하위 세션은 분기해 표시 |
| 오른쪽 | 선택한 항목의 명령·인수·결과, 종료값, 출처, 연결 근거, 전체 본문 |
| 하단 | 소스·빌드·테스트·설치·런타임·실제 기기·배포별 확인 근거와 미확인 범위 |

기본 화면은 현재 진행 위치와 결과를 기다리는 호출을 먼저 보여준다. 완료한 호출은 사용자가 펼칠 수 있는 묶음으로 접는다. 현재 요청에 속하지 않은 과거 하위 세션은 접힌 별도 목록에 둔다. 명시된 작업 계획이 없으면 화면 제목을 자동 생성한 의미 단계로 채우지 않는다.

관계는 색만으로 구분하지 않는다. 선의 형태와 라벨을 함께 사용한다. 선택 항목은 키보드로 이동하고 접근성 설명에서 상태·출처·관계 종류를 읽을 수 있어야 한다. 새 자료를 추가해도 현재 선택과 확대 위치를 유지한다. 진행 위치가 바뀌면 사용자가 이동할 수 있는 표시를 제공하며 자동으로 화면을 끌고 가지 않는다.

## 5. 데이터 계약 제안

기존 `ContextTopology`는 기록 지도와 판단 입력에 유지한다. 새 모델은 원시 기록 ID를 참조하는 별도 읽기 모델로 만든다. 후보 이름은 `SessionWorkTopology`, `WorkNode`, `WorkRelation`, `WorkEvidence`, `WorkCoverage`다.

| 모델 | 필수 정보 |
| --- | --- |
| WorkNode | stable ID, session ID, turn ID, 종류, 제목, 기록 상태, 원본 시각, source refs |
| WorkRelation | 종류, 출발·도착 ID, 관찰/제안 구분, 관계를 입증한 source refs |
| WorkEvidence | 대상 노드, 근거 종류, 출처 위치, 관찰 결과, 주장한 결과, 확인 범위 |
| WorkCoverage | 출처·파일 세대·읽은 범위, 부분 읽기·누락·갱신 상태 |
| SemanticGroup | 선택 기능. 제목, 구성원 ID, 제안한 근거와 작성 주체. 원시 관계와 분리 |

노드 종류는 요청, turn, 공개 진행 보고, 도구 호출, 구조화된 명령·MCP 실행, 도구 결과, 위임, 하위 세션 보고, 산출물 참조, 검증 근거를 포함한다. 내부 reasoning을 작업 단계로 사용하지 않는다.

관계 종류는 `belongsToTurn`, `resultOf`, `spawnedSession`, `reportedBy`, `referencesArtifact`, `supportsClaim`, `recordedNext`, `dependsOn`을 구분한다. `recordedNext`는 기록 순서만 나타낸다. `dependsOn`은 명시한 계획이나 연결 계약이 있을 때만 만든다.

관계 연결 규칙은 다음과 같다.

1. 직접 `turn_id` 또는 메시지 metadata의 `turn_id`로 요청·항목을 turn에 연결한다. ID가 없으면 시작 이벤트 구간에 따른 연결임을 표시한다. 모호하면 소속 미확인으로 남긴다.
2. 직접 `call_id`로 도구 호출과 결과를 연결한다. 다른 호출의 결과를 같은 제목이나 시각만으로 합치지 않는다.
3. `item_completed`의 내부 item ID로 실제 명령·MCP 실행을 복원한다. response item과 동일한 item ID일 때 중복 표현의 출처를 병합한다.
4. 내부 실행과 `exec` wrapper 사이에 명시된 부모 호출 ID가 없으면 같은 turn 아래에 둔다. JavaScript 내용이나 시간 근접성만으로 실행 계층을 확정하지 않는다.
5. 부모 세션 ID로 세션 계층을 만든다. 생성 호출의 결과 경로와 DB의 `agent_path`가 일치하면 위임 호출과 세션을 연결한다. 생성 turn과 후속 요청 turn은 각각 보존한다.
6. 명시된 sender·recipient·item ID로 하위 세션 보고를 연결한다. 보고 수신을 구현 검증 성공으로 바꾸지 않는다.
7. 파일 경로가 기록에 등장하면 우선 참조로 표시한다. 실제 파일 존재·hash·생성 이벤트를 확인한 뒤 산출물 근거를 추가한다.

## 6. 상태와 완료의 의미

세션의 IPC 상태, 기록된 turn의 상태, 도구 실행 상태, 사용자 목표의 충족 여부는 별도 필드다.

| 관찰 | 표시할 의미 |
| --- | --- |
| IPC running | 현재 세션 실행 상태. 어떤 단계가 실행 중인지는 별도 기록 필요 |
| task_started, 종료 없음 | 기록에서 시작을 확인한 turn. 현재 실행 여부는 최신 IPC·기록 시각과 함께 표시 |
| 호출, 결과 없음 | 결과 미수신. 최신 상태를 확인할 수 없으면 실행 중으로 단정하지 않음 |
| 결과 수신 | 결과 기록 있음. 성공 여부는 결과 계약으로 판단 |
| CommandExecution exit_code 0 | 명령 종료값 0. 관련 빌드·테스트 전체가 성공했는지는 해당 계약과 로그를 확인 |
| MCP result.isError | 명시된 도구 오류. status와 함께 보존 |
| task_complete | 해당 turn의 응답 종료. 요청의 목표 충족 여부는 별도 |
| turn_aborted | 기록된 중단. 미수신 결과를 성공으로 채우지 않음 |
| 목표 충족 | 명시한 수용 기준과 연결된 근거가 있을 때 표시. 근거가 없으면 확인 전으로 유지 |

백분율은 수용 기준과 분모가 명시돼 있을 때만 표시한다. 임의의 단계 수를 기준으로 진행률을 만들지 않는다. 요청 원문·수정 지시를 보존하며, 후속 사용자 입력이 현재 목표의 수정인지 새 목표인지 자동으로 확정하지 않는다.

## 7. 같은 세션에 적용하는 예

현재 기획 요청은 18:37 KST의 검사 시점에 시작 이벤트와 기록 항목이 있었으며 종료 이벤트는 없었다. 첫 화면에는 현재 요청, 코드·설치 앱·저장 기록 조회, 결과를 기다리는 호출을 표시한다. `구현 확인 / 구조 기획 / 문서와 다이어그램 작성`이라는 묶음은 이 기획에서 제안한 제목이다. 실제 실행 기록에 존재하는 단계 이름으로 주장하지 않는다.

직전 설치 turn `01a105fb-85da-75b1-80d3-049c5a25cdc2`는 비교 사례로 사용할 수 있다. 사용자 승인, 교체 작업, 파일 hash와 서명 확인, 앱 실행과 기본 창 확인을 각각 다른 근거로 연결한다. `make install`의 성공은 설치 근거다. 앱의 기본 창과 Codex 연결은 실행 관찰이다. 이 기록으로 사용자 정의 판단 편집 흐름 전체가 검증됐다고 표시하지 않는다. [설치 로그](../evidence/decision-compatibility-install-final.log)와 [설치 manifest](../evidence/decision-compatibility-artifact.json)는 해당 단계의 근거로 연결할 수 있다.

하위 세션 네 개는 과거 협업 구조를 보여주는 사례다. 현재 turn에서 새 위임을 관찰하지 않았으므로 현재 실행 분기에 네 개를 모두 활성 상태로 표시하지 않는다.

## 8. 큰 기록과 실시간 갱신

현재 상세 조회는 전체 rollout을 처음부터 읽는다. 이번 소스는 약 104MB다. 작은 화면에서 18개 노드만 그리더라도 전체 파싱과 인덱스 생성 비용은 남는다. 현재 수량 검사는 성능 측정이 아니므로 지연 시간이나 메모리 개선 수치를 주장하지 않는다.

제안하는 읽기 경로는 다음과 같다.

- 최초 진입은 카탈로그와 현재 IPC 상태를 먼저 표시한다. 기록 인덱스는 utility 작업에서 만든다.
- 인덱스는 세션 ID, 파일 세대, byte offset, native item ID, turn ID와 body reference를 저장한다. 재생성 가능한 앱 소유 캐시로 두고 Codex 파일에는 쓰지 않는다.
- 인덱스가 없으면 파일 끝에서 시작해 완전한 현재 turn의 시작 경계까지 읽는 방안을 검증한다. 고정된 마지막 N개만 읽고 완전한 현재 작업이라고 표시하지 않는다. 경계를 찾지 못하면 확인 범위를 유지하며 읽기를 확장한다.
- 전체 기록 인덱스는 별도 작업으로 이어서 만든다. 과거 조회는 선택한 turn의 인덱스를 사용한다.
- 열린 세션의 새 줄만 추가로 읽는다. 마지막 불완전한 줄은 버퍼에 유지하고 줄이 완성되기 전에는 오류나 완료로 확정하지 않는다.
- 파일 교체·축소·경로 변경은 세대를 변경해 재색인한다. 이전 본문 참조는 그대로 적용하지 않는다.
- 파일 변경 알림을 합치고 취소할 수 있게 한다. 상태 패치마다 104MB를 다시 파싱하지 않는다.
- 검색·필터·화면에 보이는 노드를 위한 인덱스를 유지한다. 표시 묶음을 접어도 기록을 삭제하거나 결과를 조용히 생략하지 않는다.

성능 목표는 구현 첫 측정에서 확정한다. 최소 수용 조건은 메인 스레드에서 전체 파일 파싱을 하지 않고, 변경이 없는 새로 고침에서 전체 재파싱을 하지 않으며, 100MB 이상 기록의 cold/warm/append 조회 시간과 peak memory를 각각 보고하는 것이다.

## 9. 구현 순서와 종료 조건

| 순서 | 구현 범위 | 종료 조건 |
| --- | --- | --- |
| 0. 실제 기록 어댑터 | `subagent` 계약, 중첩 `item_completed`, 실제 타입 이름, 중복 출처 병합 | 현재 세션의 4개 하위 관계와 실제 명령·MCP 항목을 ID로 복원. 기존 기록 탐색 계약 유지 |
| 1. 현재 작업 구조 | turn·요청·호출·결과 모델, 현재 turn 기본 보기, 상태·갱신 시각 | 현재 요청과 실행 위치에 첫 화면에서 접근. 오류·중단·결과 미수신을 완료로 표시하지 않음 |
| 2. 위임·근거·갱신 | 위임/보고 관계, 산출물·검증 근거, 증분 인덱스와 현재 범위 갱신 | 과거 하위 세션과 현재 위임 구분. 근거 종류 구분. 추가 기록 반영 시 선택 유지 |
| 3. 의미 단계 제안 | 공개 계획·진행 보고를 이용한 묶음, 필요할 때 공통 판단 계층 사용 | 제안 표시, 구성원 ID와 근거 확인, 재명명·해제 가능. 원시 관계를 덮어쓰지 않음 |

첫 납품 단위는 0–1단계다. 2단계까지 완료하면 사용자가 현재 작업, 위임 관계와 검증 범위를 함께 볼 수 있다. 3단계의 Jev 활용은 선택 사항이다. 결정적인 ID 연결이나 실행 성공 판정에 의미 추론을 필수로 넣지 않는다. 이 기획 확인에서 API 호출이나 새 에이전트 실행은 하지 않았다.

## 10. 구현 시 필요한 검증

| 검증 영역 | 수용 기준 |
| --- | --- |
| 어댑터 | 실제 관찰한 lowercase `subagent`와 보존해야 할 기존 표현을 fixture로 검사. 중첩 CommandExecution/McpToolCall의 성공·오류를 검사 |
| 소속·중복 | turn ID가 있는 항목, 없는 항목, 동일 item의 두 표현, 중복 call/result, 순서가 뒤바뀐 결과를 검사 |
| 완료 경계 | 호출 레코드 status만 completed인 경우, 결과 없는 호출, exit 0이지만 검증 미완료, turn 종료지만 목표 미충족을 구분 |
| 동시성·갱신 | 범위 전환·닫기·지연 완료·취소, 부분 줄, rotation·truncate, 삭제·권한 오류에서 이전 안전한 상태 유지 |
| 협업 | 명시한 부모 ID·agent_path·보고 ID로 연결. 생성된 과거 세션을 현재 위임으로 오인하지 않음 |
| 근거 | 존재하는 파일 참조와 확인한 산출물 구분. source/build/test/UI/device/release 근거의 종류 유지 |
| 성능 | 이 규모의 기록에서 cold/warm/append 시간과 메모리를 별도로 측정. 변경 없는 갱신의 전체 재파싱 0회 |
| 네이티브 UI | 현재 요청 찾기, 진행 위치, 호출·결과·근거 펼치기, 과거 turn, 기록 지도 전환, 키보드·VoiceOver, 갱신 중 선택 보존 |
| 기존 회귀 | 카탈로그, 기록 본문·fingerprint, scope cancellation, 저장 실패 복원, 초안 보호, 무전송, 판단 입력, 드래그 관찰 회귀 유지 |

## 11. 이번 확인의 범위

이번에는 설치 앱의 단일 세션 상세 지도, 도구 호출·결과 관계, checkout 소스와 실제 저장 기록의 구조를 확인했다. 첫 진입 전 `unable to open database file` 알림이 한 번 있었고 닫은 뒤 상세 조회는 성공했다. 원인은 이번 기획에서 진단하지 않았다.

문서·다이어그램·관찰 근거만 추가했다. 설치 빌드의 source manifest와 소스·테스트·빌드 설정 68개 파일을 비교했으며 변경이나 누락은 없었다. 근거는 [소스 일치 검사](../evidence/session-work-topology-source-identity.json)에 있다. 앱을 다시 빌드하거나 설치하지 않았다. 기존 176개 테스트 결과는 이전 수정본의 근거다. 이번 새 작업 구조 기능의 검증 결과로 재사용하지 않는다.

다이어그램은 workflow v2다. `deliver`의 showcase 검사는 9/9, 오류 0, 경고 0이었다. 자동 브라우저 검사는 1440×900, 1600×1000, 1920×1080, 2048×1320에서 페이지 넘침이 없었다. 1440×900과 2048×1320의 밝은·어두운 캡처 네 장을 이미지로 직접 확인했다. 상세 상호작용과 export 전체는 이 캡처 검사 범위에 포함하지 않는다. 고정 Viewer UI와 HTML 언어는 영어이며 작성한 도메인 설명은 한국어다.

근거: [전달 receipt](../evidence/session-work-topology-diagram-delivery.json), [자동 브라우저 receipt](../design-previews/session-work-topology-plan.visual-check.json), [별도 시각 검토](../evidence/session-work-topology-visual-review.json), [네이티브 관찰](../evidence/session-work-topology-native-observations.json).

## 12. 변경을 담당할 경로

| 경로 | 책임 |
| --- | --- |
| `Sources/MaestroCore/CodexCatalog.swift:49` | 실제 하위 세션 source 계약 |
| `Sources/MaestroCore/ContextTopologyLoader.swift:55` | 기록 해석·호출/결과 연결·body reference. 기존 계약 보존 |
| `Sources/MaestroCore/ContextTopology.swift:3` | 기존 기록 모델. 새 작업 모델과 관계 구분 |
| 새 `Sources/MaestroCore/SessionWorkTopology.swift` | 작업 노드·관계·근거·확인 범위 |
| 새 `Sources/MaestroCore/SessionWorkTopologyLoader.swift` | 구조화된 실행 항목·turn·위임 해석 |
| 새 `Sources/MaestroCore/SessionWorkIndex.swift` | 파일 세대·범위·증분 조회 |
| `Sources/CodexMaestro/ContextInspectionStore.swift:18` | 조회 수명·범위·취소 관리 |
| `Sources/CodexMaestro/MaestroStore.swift:245` | 실시간 상태 연결. 전체 기록 재파싱과 분리 |
| `Sources/CodexMaestro/ContextTopologyView.swift:4` | 작업 구조/기록 지도 전환 |
| 새 `Sources/CodexMaestro/SessionWorkTopologyView.swift` | 현재 요청·실행·위임·근거 UI |
| `Tests/MaestroCoreTests/ContextTopologyLoaderTests.swift` | 기존 원시 탐색 계약 유지 |
| `Tests/MaestroAppTests/ContextInspectionTests.swift` | 기존 취소·초안·저장·무전송 계약 유지 |

새 경로는 기획상의 후보이며 아직 존재하는 구현 파일이 아니다. 실제 구현에서는 기존 테스트 전체와 Xcode 검사 절차를 유지한다.
