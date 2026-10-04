# 공통 판단 계층

CodexMaestro는 `MaestroCore`의 공통 판단 계층과 사용자 정의 판단 화면을 제공한다. Swift의 `URLSession`이 TypeSafe HTTP API를 직접 호출한다. 질문 ID, 선택지 ID, 평가 기준에는 앱 기능 이름을 고정하지 않는다.

현재 구현은 기획의 1–4단계에 해당한다. HTTP 계약과 실행 계획은 XCTest로 검증했다. 인증된 실제 API에는 합성 입력을 전송해 계약의 경계 조건을 확인했다. 현재 코드로 저장된 32건을 다시 검사한 결과도 일치했다. 한국어 업무 자료의 판단 품질은 별도로 검증해야 한다. 검증 근거는 [VALIDATION.md](VALIDATION.md)에 있다.

## API 계약

| 입력 또는 응답 | 구현 |
|---|---|
| state | 문자열·객체·배열. 중첩 구조, JSON 숫자, 배열 순서 보존 |
| questions | 동적 ID map. 단일·동종·혼합 Choice/Score/Noul |
| instructions | 생략 또는 문자열·객체·배열·null |
| Choice | 1–255개 동적 선택지. 선택 ID·전체 확률 분포·confidence |
| Choice 기준 설명 | 문자열·객체·배열·null |
| Score | 순서가 있는 1–10개 단계. 점수·확률 분포·legend·confidence. 정규화와 순위 계산은 2단계 이상 |
| Score 기준 설명과 legend | 문자열·객체·배열. 설명 내부의 null은 보존하며 단계 자체의 null은 거부 |
| Noul | criteria 생략·null·true/false 설명 객체. 비어 있지 않은 지시문 또는 null이 아닌 기준 설명 필요. yes 확률. 별도 confidence 없음 |
| 모델 | 모델 ID 또는 alias 입력. GET `/v1/models`. 실제 응답 모델 기록 |
| 원본 응답 | 타입이 있는 답, 원본 JSON, 원본 bytes와 사용량 보존 |
| 오류 | 인증·HTTP 오류·transport·응답 계약 오류·취소 구분 |

필수 답 누락, 질문 타입 불일치, 범위를 벗어난 값, 누락된 확률 분포는 실패로 반환한다. 해석하지 않은 새 응답 필드는 원본에 보존한다. 후속 요청과 조건식에는 검증한 필드만 노출한다.

기준은 [공개 OpenAPI](https://api.typesafe.ai/openapi.json), [HTTP API](https://docs.typesafe.ai/api), [구조화된 입력](https://docs.typesafe.ai/primitives/advanced), [모델](https://docs.typesafe.ai/models) 문서다. 2026-10-04 확인 시점에 공식 자료 사이의 차이가 있었다. HTTP 설명은 Score를 2–10단계로 설명하지만 OpenAPI는 최소 1단계다. Advanced 문서와 [공식 JavaScript SDK v0.6.0](https://github.com/typesafe-ai/typesafe-sdk-js/blob/v0.6.0/src/types.ts)은 Score 단계 자체의 null을 허용한다. 공개 OpenAPI와 실제 서버는 해당 null을 허용하지 않는다.

실제 `jev-1.13.0` 응답에서 Score 1·2·10단계는 성공했고 0·11단계는 거부됐다. 1단계 Score는 원본 점수 0과 단일 확률 분포를 조회할 수 있다. `score / (단계 수 - 1)`의 분모가 0이므로 정규화와 순위 계산은 실행 전에 거부한다. 동적 기준도 참조를 해석한 뒤 같은 검사를 적용한다.

Noul의 빈 지시문 문자열·객체·배열은 지시문이 없는 경우로 취급한다. 이 경우 true 또는 false 기준 설명 중 하나가 null이 아니면 서버가 허용했다. 기준 설명의 빈 문자열·객체·배열과 중첩 null은 허용했다. 공백 문자열도 임의로 제거하지 않는다. 기준만으로 정의한 Noul을 허용하며, 지시문과 유효한 기준이 모두 없는 조합만 거부한다. 이 관찰은 요청 호환성 근거이며 빈 설명의 판단 품질 근거는 아니다.

형식 오류는 `/questions/q/criteria/0`과 같은 필드 경로를 표시한다. HTTP 오류는 서버의 `detail`과 `loc`를 표시하고 응답 원본 bytes를 trace에 보존한다. 로컬 형식 검사와 저장된 응답의 재검사는 위 경계 조건의 호환성을 확인하며, API 전체나 향후 서버 변경을 보장하지 않는다.

## 구성요소

| 구성요소 | 책임 |
|---|---|
| DecisionJSON | 구조 보존, JSON Pointer, 정규화한 SHA-256 fingerprint |
| QuestionSpec / DecisionRequest | 공통 HTTP 요청 계약과 형식 검사 |
| DecisionResponse | 검증한 판단값과 전체 응답 보존 |
| TypeSafeHTTPClient | 인증, URLSession, 모델 조회, rate limit 재시도 |
| DecisionProfile / DecisionPlan | 질문·기준·버전·의존 관계·분기·자료 조회·결과 규칙 |
| DecisionEngine | 요청 묶음, 병렬 실행, 취소, 진행 상태, 캐시, 근거 확인 범위 |
| DecisionComposer | 정규화한 가중 평균, 필수 조건, 정렬, 다중 라벨, 원본 선택 |
| DecisionResult | 원시 판단과 조합 결과, 상태, fingerprint, 근거, trace, 사용량 |
| DecisionBinding | 결과와 알려진 업무 handler의 연결 |

같은 state를 사용하는 독립 단계는 질문을 혼합한 요청 하나로 실행한다. 서로 다른 state를 사용하는 독립 단계는 병렬로 실행한다. 이전 답이 필요한 단계는 의존 단계를 명시하고 완료 후 실행한다. 계획은 순환이 없는 그래프다. 반복 검증은 후속 단계를 추가하거나 새 입력으로 계획을 다시 실행한다.

## 사용자 정의 판단

툴바의 **사용자 정의 판단** 버튼에서 Profile을 선택하거나 구성한다. 화면은 실행, 질문과 계획, 결과 조합, 원본 JSON의 네 영역으로 나뉜다.

- 입력은 프로젝트, 세션, 기록, 초안 또는 직접 입력한 JSON에서 선택한다.
- 프로젝트와 세션은 자료 요약·후보 map·확인 범위를 먼저 불러온다. 본문은 계획에서 선택한 자료 ID만 후속으로 읽는다.
- 기록은 선택한 본문을, 초안은 현재 초안의 원문을 불러온다.
- 질문 종류와 구조화된 instructions·criteria를 편집한다. JSON 편집기의 변경은 **JSON 적용**을 누를 때 정의에 반영된다.
- 의존 단계, 실행 조건, 후속 자료 ID, 가중치, 필수 조건, 라벨, 원본 선택과 handler를 구성한다.
- Profile을 저장·복제·가져오기·내보내기한다. 새 판단을 추가할 때 앱 코드를 변경할 필요가 없다.
- 실행 결과에서 판단값과 조합 결과를 확인한다. 원본 JSON 영역에서 실제 요청·응답·모델·근거 확인 범위를 확인한다.

API 키는 Profile과 분리한다. 사용자가 선택하면 Keychain에 저장한다. Profile은 `~/Library/Application Support/CodexMaestro/decision-profiles.json`에 저장한다. 저장 파일의 권한은 `0600`이다. 기존 저장 파일을 읽지 못하면 덮어쓰지 않는다. 데모 모드의 Profile 저장 경로는 프로세스별 임시 폴더다. API 실행은 입력을 TypeSafe에 전달하며, 키가 없으면 요청을 시작하지 않는다.

## 후속 입력과 동적 후보

`$ref`는 `/input` 또는 검증한 이전 답을 참조한다. 리터럴 문자열을 보간하지 않는다. 문자열 안에 참조 표현을 적으면 그대로 전달한다.

```json
{"$ref":"/input"}
```

```json
{"$ref":"/steps/choose/answers/record/choice"}
```

`$lookup`은 이전 선택값으로 기존 객체나 배열의 항목을 읽는다. 다음 후보 집합, 구조화된 설명 또는 원본 값에 사용할 수 있다. 객체의 key는 문자열이다. 배열의 key는 음수가 아닌 정수다. 누락된 항목은 입력 부족으로 반환한다.

```json
{
  "$lookup": {
    "source": {"$ref":"/input/children"},
    "key": {"$ref":"/steps/project/answers/target/choice"}
  }
}
```

위 표현을 후속 Choice의 criteria로 사용하면 이전 단계에서 선택한 프로젝트의 하위 후보만 전달한다. 해당 단계는 `project`를 의존 단계에 포함해야 한다. `$ref` 또는 `$lookup`만 포함한 객체는 템플릿 연산자다. 다른 키를 포함한 객체는 각 값을 해석하는 일반 객체다. 이 연산자는 기존 값을 선택하며 새로운 원문을 생성하지 않는다.

후속 자료 ID를 지정한 단계의 state는 다음 구조로 전달한다. `base`에는 단계에서 구성한 state가 들어간다. `evidence`에는 읽은 자료 ID와 본문이 들어간다.

```json
{
  "base": {"goal":"검토 목표", "selected":"자료 ID"},
  "evidence": [{"id":"자료 ID", "body":"전체 본문"}]
}
```

[summary-to-full-profile.json](examples/summary-to-full-profile.json)은 앱에서 가져올 수 있는 예제다. 프로젝트 또는 세션 입력에서 요약 후보를 선택하고, 선택한 자료의 본문을 읽어 관련성과 제약을 평가한다. `0.8` 라벨 조건은 구성 방식의 예시다. 한국어 업무 자료에서 품질을 검증한 임계값은 아니다.

## 조합 방식

| 사용 방식 | 구성 |
|---|---|
| 단일 판단 | 단계 하나와 질문 하나 |
| 병렬 판단 | 같은 state의 여러 질문 또는 독립 단계 |
| 조건부 결과 사용 | 단계·binding의 조건, 조건식의 all/any/not |
| 다중 라벨 | 독립 질문의 결과에 대한 여러 라벨 조건 |
| 후보 선택 | 동적 Choice criteria와 선택 ID |
| 후보별 순위 | 공통 기준의 Score 또는 Noul을 후보별로 참조 |
| 복합 평가 | 평가 축의 가중 평균과 별도 필수 조건 |
| 계층 탐색 | 의존 단계와 `$lookup`으로 하위 후보 조회 |
| 단계적 근거 확장 | 요약 선택 후 등록한 자료 ID의 본문 조회 |
| 값·원문 선택 | Choice 결과로 기존 값 map에서 원문 선택 |
| 검증과 재평가 | 검증 답에 따른 분기·후속 자료 조회·후속 질문 |
| 함수 라우팅 | 선택값을 알려진 handler와 인수에 연결 |
| 상태 변화 대응 | 입력과 Profile의 유효성 확인 후 새 입력으로 재실행 |

2단계 이상의 Score는 `score / (단계 수 - 1)`로 0–1에 정규화한다. 1단계 Score는 원본 조회만 허용한다. Noul은 yes 확률을 사용한다. Choice의 상대 확률은 후보별 전역 순위나 가중합에 사용할 수 없다. 필수 조건을 충족하지 않은 후보는 높은 가중 점수로 통과하지 못한다. confidence 조건은 Choice와 Score 질문별로 설정한다. Noul에는 confidence 조건을 설정할 수 없다.

## 큰 입력, 재시도와 캐시

질문 개수와 작업 호출 횟수에 임의의 상한을 두지 않는다. Choice 선택지와 Score 단계의 수는 공개 API 계약을 따른다. HTTP 429·529는 `Retry-After` 또는 지수 backoff로 재시도한다. 기본 재시도는 최초 요청 이후 세 번이며, 이는 작업 횟수 제한이 아니다. 인증 실패와 일반 422는 자동 재시도하지 않는다.

서비스가 413 또는 명시적인 입력 한도 오류 코드를 반환하면 독립 질문 묶음을 나눈다. 분할 요청은 동일한 state 전체를 유지한다. 단일 질문도 한도를 넘으면 `inputAdjustment`를 반환한다. 원문을 조용히 자르지 않는다. 일반 422의 원인을 입력 한도로 추측하지 않는다.

메모리 캐시는 입력·근거 fingerprint, 실제 요청, 질문 버전, 기준 버전에 연결한다. 버전이 고정된 모델 요청만 캐시한다. 응답 모델이 요청 모델과 다르면 캐시하지 않는다. alias 요청은 캐시하지 않는다. 자료·목표·초안·Profile이 바뀌면 이전 결과를 현재 결과로 적용할 수 없다.

## 결과 적용과 검증 경계

앱은 `copyValue`, `openContext`, `compareSessions`, `prepareDraft` handler를 제공한다. handler는 결과 화면에서 사용자가 직접 실행한다. 대상 세션·프로젝트는 사용자가 선택한 허용 대상과 일치해야 한다. 적용 직전에 자료의 현재 상태와 선택한 본문을 다시 확인한다. 알 수 없는 handler와 오래된 결과는 거부한다.

`prepareDraft`는 기존 초안을 보호한다. 저장에 실패하면 작업공간과 선택 상태를 복원한다. 전송은 기존 세션 화면에서 사용자가 직접 실행한다. 모델의 확률과 실행 권한은 별개다.

결과 상태는 `succeeded`, `insufficientInput`, `insufficientJudgment`, `inputAdjustment`, `apiError`, `invalidProfile`, `cancelled`, `stale`을 구분한다. API 실패를 자료 없음으로 바꾸지 않는다. 본문을 읽은 뒤 API가 실패한 경우에도 읽은 근거 확인 범위를 보존한다.

현재 검증은 공통 계약·실행 계획·Profile 저장·앱 적용 경계와 합성 입력의 실제 서비스 호환성을 대상으로 한다. 실제 UI 편집 흐름, 한국어 판단 품질과 5단계의 자동 추천 기능은 별도 검증 또는 구현 대상이다.
