# KakaoTalk CLI for macOS

Mac 카카오톡 앱을 직접 제어하는 독립 Swift CLI입니다. 실행 명령은 `kakao`입니다.
기존 `kakaocli`, 에이전트 스킬, 비공개 카카오 프로토콜에 의존하지 않습니다.
Apple의 접근성 API로 로컬 앱과 통신하며, 명령어 해석에는 Swift Argument Parser, LLM 연결에는 공식 Swift MCP SDK를 사용합니다.
카카오가 제공하거나 보증하는 공식 도구는 아닙니다.

## 현재 지원 범위

- 앱 설치·실행 여부와 접근성 권한 진단
- **별도 창으로 이미 열려 있는 대화** 목록 조회
- 이름으로 대화 검색 및 **닫힌 대화창 자동 열기**
- 해당 대화에서 **앱에 이미 불러온 텍스트 행** 읽기와 검색
- 메시지 미리보기, 대화명 재확인 후 전송
- Claude Desktop, Claude Code, Codex, Gemini CLI 등에서 호출하는 로컬 MCP 서버
- JSON 출력 및 개인정보를 기본 숨김 처리하는 화면 구조 진단

아직 전체 계정의 대화 목록 일괄 수집, 전체 과거 기록 검색, 첨부파일 전송, 자동 로그인, 새 메시지 감시와 자동 답장은 지원하지 않습니다.
자동 열기는 앱의 메인 창에서 이름을 검색한 뒤 별도 대화창을 엽니다. 카카오톡이 실행·로그인되어 있고 메인 창이 존재해야 합니다.
검색과 열기는 앱을 앞으로 가져오고 검색어·선택 상태를 바꿉니다. **대화를 열면 읽음 처리될 수 있습니다.** 검색 결과가 정확히 하나로 좁혀지지 않으면 중단합니다.
텍스트 행에는 본문 외에 이름·시각·날짜 등 앱이 공개하는 화면 문구가 포함될 수 있습니다. 이미지와 파일 내용은 추출하지 않습니다.
메시지 ID, 작성자, 서버 시각을 추측해서 만들어내지 않습니다.

## 준비

저장소를 내려받고 프로젝트 폴더로 이동합니다.

```sh
git clone https://github.com/breadtae/kakao-cli.git
cd kakao-cli
```

1. macOS용 카카오톡을 실행하고 직접 로그인합니다. 잠금 화면이나 확인창은 닫습니다.
2. Swift 6.0 이상과 Xcode Command Line Tools가 필요합니다. 실행 대상은 macOS 13 이상입니다.
3. 이 프로젝트 폴더에서 `make build`를 실행합니다. 첫 빌드에는 의존성 다운로드를 위한 인터넷 연결이 필요합니다.
4. `.build/release/kakao status --request-access`로 권한 안내를 표시합니다.
5. **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 실행 중인 터미널 또는 VS Code를 허용합니다. macOS가 실행 파일을 별도로 표시하면 해당 항목을 허용합니다.
6. `.build/release/kakao status --json`의 `accessibilityGranted`가 `true`인지 확인합니다.

전체 디스크 접근 권한, 카카오 비밀번호, API 키는 필요하지 않습니다.
빌드나 설치 위치를 바꾼 뒤 권한이 인식되지 않으면 해당 실행 위치에서 다시 상태를 확인합니다.

## 실행과 설치

설치 없이 `.build/release/kakao --help` 또는 `swift run kakao --help`로 실행할 수 있습니다.

`make install`은 실행 파일을 `~/.local/bin/kakao`에 설치합니다. 관리자 권한은 필요하지 않습니다.
해당 폴더가 `PATH`에 없다면 `~/.local/bin/kakao`로 실행합니다. 셸 설정은 자동으로 변경하지 않습니다.
설치 위치 변경은 `make install PREFIX=/원하는/경로`로 지정합니다.

아래 예시의 `kakao`는 설치한 실행 파일을 뜻합니다. 미설치 상태에서는 `.build/release/kakao`로 바꿔 실행합니다.

## 명령어

| 목적 | 명령 |
| --- | --- |
| 상태 확인 | `kakao status --json` |
| 권한 요청 | `kakao status --request-access` |
| 열린 대화창 목록 | `kakao chats --json` |
| 닫힌 대화도 이름으로 검색 | `kakao find-chats "대화창 이름" --json` |
| 대화창 자동 열기 | `kakao open-chat --chat "대화창 이름" --json` |
| 불러온 마지막 30개 행 읽기 | `kakao messages --chat "대화창 이름" --limit 30 --json` |
| 불러온 마지막 100개 행에서 검색 | `kakao search "검색어" --chat "대화창 이름" --limit 100 --json` |
| 전송 미리보기 | `kakao send --chat "대화창 이름" "안녕하세요" --dry-run --json` |
| 화면 구조 진단 | `kakao inspect --max-depth 8 --max-nodes 500` |

`messages`와 `search`는 대상 창이 없으면 자동으로 찾아 엽니다. 화면을 조작하지 않으려면 `--no-open`을 붙입니다.
`--chat`은 `chats` 또는 `find-chats`에서 나온 제목과 정확하게 일치해야 합니다. 부분 일치와 대소문자 추측은 하지 않습니다.
같은 제목의 창이 여러 개 있으면 하나를 임의로 고르지 않고 중단합니다.
‘나와의 채팅’도 창 제목은 본인 프로필 이름일 수 있으므로 목록의 제목을 사용합니다.

읽기·검색의 `--limit`은 1~200이며, 서버 메시지 수가 아니라 **확인할 화면 행 수**입니다.
스크롤하거나 추가 기록을 다운로드하지 않습니다. 검색은 이 범위 안에서 대소문자를 구분하지 않고 수행합니다.
JSON의 `scope`는 `loaded-ui`, `availableRows`는 앱이 공개한 행 수, `scannedRows`는 검사한 행 수입니다.
`limited: true`이면 지정한 개수보다 더 많은 행이 앱에 불러와져 있습니다.
텍스트가 없는 행은 결과에서 빠질 수 있습니다.

## 실제 전송

`send`는 기본적으로 **미리보기만** 수행하며, 입력창에 글자를 넣거나 앱을 앞으로 가져오지 않습니다.
미리보기 역시 실제 창과 전송 버튼을 확인하므로 앱 실행과 접근성 권한이 필요합니다.
직접 쓰는 CLI의 `send`는 기존 동작을 유지하므로 창이 닫혀 있다면 먼저 `open-chat`을 호출합니다. MCP의 미리보기·전송 도구는 필요한 경우 자동으로 엽니다.

실제 발송은 `kakao send --chat "대화창 이름" "보낼 내용" --execute --confirm-chat "대화창 이름"`으로 명시적으로 요청합니다.
대화명과 내용을 먼저 확인하고 실행하세요. 에이전트에서 호출할 때도 사용자의 최종 발송 승인이 필요합니다.

본문을 셸 명령 기록에 남기지 않으려면 메시지 인자 대신 `--stdin`을 사용합니다.
예: `kakao send --chat "대화창 이름" --stdin --dry-run < message.txt`
입력은 UTF-8이어야 하며 줄바꿈을 그대로 보존합니다. `--stdin`은 파이프 또는 파일 입력 전용입니다.
본문 인자와 `--stdin`은 함께 사용할 수 없습니다.

전송 안전장치:

- `--execute`와 정확한 `--confirm-chat`이 모두 필요합니다. `--dry-run`과 `--execute`는 함께 사용할 수 없습니다.
- 입력창에 기존 초안이 있으면 덮어쓰거나 지우지 않습니다.
- 전송 직전에 창, 입력창, 전송 버튼, 키보드 포커스와 본문을 다시 확인합니다.
- 입력창과 버튼이 명확하지 않거나 확인창이 떠 있으면 중단합니다. 좌표 클릭이나 전역 Enter 키로 대신 보내지 않습니다.
- 대화창을 열 때에만 접근성으로 확인한 이름 요소의 위치를 사용해 더블클릭합니다. 클릭 직전 해당 위치가 정확한 검색 결과에 속하는지 다시 검사합니다. 화면 배율이나 위치를 고정값으로 가정하지 않습니다.
- 클립보드는 읽거나 바꾸지 않습니다.
- 같은 사용자의 CLI 전송은 로컬 잠금으로 직렬화합니다. 다른 자동화 도구나 직접 입력까지 잠그는 것은 아닙니다.
- 전송 중에는 키보드와 마우스 조작을 피하세요. UI 자동화는 사용자의 동시 조작과 앱 변경을 완전히 통제할 수 없습니다.
- 실패 후 남은 초안을 자동으로 지우지 않습니다. 앱에서 직접 확인하세요.
- 전송 결과가 불확실하면 자동 재시도하지 않습니다. 재실행 전 실제 대화를 확인해야 합니다.

JSON의 `state: preview`는 미발송입니다.
`state: submitted`는 앱의 전송 버튼을 누른 뒤 입력창이 비워진 것을 확인했다는 뜻이며, 서버 도착이나 상대방 수신을 보장하지 않습니다.
`deliveryVerified`는 항상 `false`입니다. 오프라인 전송 대기나 서버 오류는 앱에서 확인하세요.
이 CLI의 자체 안전 한도는 본문 4,000 UTF-16 단위, 표준 입력 16,000바이트입니다. 카카오 서버의 최대 길이를 의미하지 않습니다.

## 다른 LLM 연결

`kakao mcp`는 이 Mac에서 실행되는 표준입출력 MCP 서버입니다. LLM 앱이 필요할 때 실행하므로 별도 서버를 터미널에 띄워둘 필요가 없습니다.
인터넷 포트나 외부 접속 주소를 열지 않으며, 이 프로그램 자체에는 LLM API 키가 필요하지 않습니다. 사용할 LLM 앱의 로그인·이용 조건은 별도입니다.
일반 웹 채팅창에 실행 파일 경로를 입력하는 것만으로 연결되지는 않습니다. **로컬 MCP를 지원하는 Mac 앱 또는 CLI**가 필요합니다.

먼저 `make build`로 최신 실행 파일을 만든 뒤 아래 설정을 적용합니다.
`config/`의 파일은 설정 예제입니다. 사용 전에 `command`의 `/absolute/path/to/kakao-cli`를 프로젝트의 실제 절대 경로로 바꾸세요. 프로젝트 폴더에서 `pwd`로 확인할 수 있습니다.
이 설정 파일의 `command`에 `~`나 `$PWD`를 넣어도 셸처럼 자동 확장되지 않습니다. 프로젝트를 옮기면 경로를 다시 수정해야 합니다.
VS Code의 `.vscode/mcp.json`은 `${workspaceFolder}`를 사용하므로 이 프로젝트를 작업 폴더로 열면 경로를 바꾸지 않아도 됩니다.
기존 앱 설정을 통째로 덮어쓰지 말고 `kakao-mac` 서버 항목만 병합하세요. 이번 작업에서는 사용자 홈의 앱 설정을 변경하지 않았습니다.

| 앱 | 준비한 설정 | 적용 방법 |
| --- | --- | --- |
| Claude Desktop | [config/claude.json](config/claude.json) | 설정의 Developer → Edit Config에서 기존 `mcpServers`에 서버 항목을 병합한 뒤 앱을 완전히 종료하고 다시 실행합니다. |
| Claude Code | [config/claude.json](config/claude.json) | 이 프로젝트에서 `claude --mcp-config config/claude.json`으로 실행합니다. 영구 등록은 아래 명령을 사용합니다. |
| Codex | [config/codex.toml](config/codex.toml) | Codex의 사용자 또는 프로젝트 설정에 `mcp_servers.kakao-mac` 항목을 병합합니다. |
| Gemini CLI | [config/gemini.json](config/gemini.json) | Gemini CLI의 사용자 또는 프로젝트 설정에서 `mcpServers`에 서버 항목을 병합합니다. 자동 승인은 꺼져 있습니다. |
| VS Code Copilot | [.vscode/mcp.json](.vscode/mcp.json) | 이 파일의 서버 시작을 선택하고 VS Code가 표시하는 신뢰 확인을 승인합니다. |

설정 파일 편집 대신 각 CLI의 등록 명령을 사용할 수도 있습니다. 아래 명령은 프로젝트 폴더에서 실행하세요. 셸이 `$PWD`를 실제 절대 경로로 확장합니다.
아래 명령은 설정을 실제로 변경하므로 자동으로 실행하지 않았습니다.

- Claude Code: `claude mcp add --transport stdio --scope user kakao-mac -- "$PWD/.build/release/kakao" mcp`
- Codex: `codex mcp add kakao-mac -- "$PWD/.build/release/kakao" mcp`
- Gemini CLI: `gemini mcp add --scope user --timeout 120000 kakao-mac "$PWD/.build/release/kakao" mcp`

각 LLM 앱에서 **“카카오톡 상태를 확인해 줘”**로 시작하세요. `kakao_status`의 `accessibilityGranted`가 `false`이면 그 앱을 손쉬운 사용에서 허용해야 합니다. VS Code에서 허용한 권한이 Claude Desktop에도 자동 적용되는 것은 아닙니다.
CLI형 LLM은 실행한 터미널, 데스크톱형 LLM은 해당 앱 또는 macOS가 안내하는 실행 파일에 권한을 부여합니다.
카카오톡 UI 자동화는 로그인된 Mac 데스크톱 세션에서 동작합니다. 클라우드 실행, Linux 컨테이너나 화면 없는 서버에서는 사용할 수 없습니다.

연결 후 요청 예시:

- “홍길동과의 최근 대화를 읽고 요약해 줘.”
- “홍길동과의 대화에서 약속 이야기를 찾아 줘.”
- “홍길동에게 보낼 답장을 만들어 미리보기만 보여 줘.”
- “확인한 문장으로 전송을 요청해 줘.”

제공 도구는 `kakao_status`, `kakao_list_open_chats`, `kakao_find_chats`, `kakao_open_chat`, `kakao_read_messages`, `kakao_search_messages`, `kakao_preview_message`, `kakao_send_message`입니다.
조회 도구의 `auto_open: false`는 자동 열기를 끕니다. 이 설정이 없으면 이름으로 자동 검색·열기 후 읽습니다.

### MCP 전송 승인

`kakao_send_message`를 호출하면 먼저 대상과 빈 입력창을 확인하고, **Mac에 대상과 전체 본문을 표시하는 승인 창**을 띄웁니다.
사용자가 `Send` 버튼을 직접 눌러야 발송합니다. 기본 버튼과 Enter 키는 `Cancel`이며, 45초 동안 응답하지 않아도 취소됩니다.
승인 전에 확인한 창과 본문을 보존하고 발송 직전에 재검증합니다. 연결 종료나 요청 취소 후에는 발송을 이어가지 않습니다.
모델이 `approved`, `execute` 같은 인자를 보내 승인 단계를 생략할 수 없습니다. 호스트의 도구 호출 승인은 별도이며, 이를 허용해도 Mac 승인 창은 유지됩니다.
이 보호는 이 MCP의 전송 경로에 적용됩니다. 같은 사용자 계정의 다른 프로그램까지 격리하는 보안 샌드박스는 아닙니다.

발송 기능 자체를 숨기고 막으려면 설정의 실행 인자에 `--read-only`를 추가합니다. 즉 실행 명령은 `kakao mcp --read-only`입니다.
이 모드에서도 검색·자동 열기는 가능하므로 읽음 처리가 일어날 수 있습니다. 읽음 변화까지 피하려면 조회 시 `auto_open: false`를 사용하고 이미 열린 창만 읽으세요.

SDK가 지원하는 MCP `2025-11-25` 연결 방식을 검증했습니다. 해당 버전과 호환되는 클라이언트가 필요하며, `2026-07-28`만 지원하는 클라이언트용 새 프로토콜은 아직 구현하지 않았습니다.

## 개인정보와 오류 처리

대화 DB, 로그인 자격증명, 비공개 네트워크 API에는 접근하지 않습니다.
대화 내용은 별도 파일로 저장하지 않습니다. 사용자가 지정한 명령의 표준 출력으로만 반환합니다.
MCP 모드에서는 요청한 결과만 연결된 호스트에 반환합니다. 클라우드 LLM을 사용하면 선택한 대화가 해당 서비스로 전달되고, 호스트가 대화나 도구 결과를 저장할 수 있습니다.
`messages`, `search`, `send --json`의 결과에는 민감한 내용이 포함될 수 있으므로 로그나 공유 파일에 남길 때 주의하세요.

`inspect`는 기본적으로 제목·본문·설명·식별자를 숨깁니다.
`kakao inspect --include-values`는 이 정보를 공개하므로 결과를 그대로 외부에 공유하지 마세요.
메뉴 진단은 `kakao inspect --menu-bar`로 실행합니다. `--include-values`를 함께 쓰면 운영체제의 최근 사용 항목 이름까지 포함될 수 있습니다.
트리 깊이·개수 한도에 걸리면 `truncated: true`가 표시됩니다.

카카오톡 업데이트로 화면 구조가 바뀌거나 앱이 응답하지 않으면 오류로 종료합니다.
이때 앱 잠금·확인창·최소화 여부와 접근성 권한을 확인하세요. 대상 창은 닫지 않고 유지해야 합니다.
오류는 표준 오류로, 성공 결과는 표준 출력으로 전달됩니다. 성공은 종료 코드 0, 입력 오류는 64, 실행 오류는 1입니다.
`status`는 준비되지 않은 상태도 진단 결과로 출력하므로, 종료 코드가 아니라 JSON의 각 상태를 확인하세요.

## 개발과 검증

`make test` 또는 `swift test`로 테스트합니다. 자동 테스트는 가짜 화면과 전송 세션을 사용하므로 실제 메시지를 발송하지 않습니다.
44개 테스트를 정의하며 기본 실행은 실제 UI를 바꾸는 3개를 건너뜁니다. 텍스트 추출, 정확한 대화 선택, 중복 이름 차단, 초안 보호, 동시 전송 잠금, MCP 연결·입력 검사, 승인·거절·취소를 검사합니다.
Mac 승인 창의 취소 시험은 `KAKAO_UI_TESTS=1 swift test --filter MCPServerTests`로 실행합니다. 가짜 대상만 표시하며 실제 발송 경로는 연결하지 않습니다.
닫힌 창 시험은 `KAKAO_UI_TESTS=1 KAKAO_TEST_CHAT="대화창 이름" swift test --filter ConversationParserTests/testClosedChatOpensAutomatically`입니다. 지정한 창의 초안이 비어 있을 때만 닫고 다시 엽니다. 메시지를 보내지는 않지만 읽음 처리될 수 있습니다.

Apple Silicon, Swift 6.3.3, 카카오톡 26.9.0 환경에서 닫힌 대화 자동 열기·읽기, MCP 실제 연결·읽기·미리보기·정상 종료, Mac 승인 창 취소를 확인했습니다.
**실제 발송은 실행하지 않았으므로 아직 실기기 발송 검증은 하지 않았습니다.** Intel Mac, 다른 macOS 버전과 카카오톡 UI 언어도 추가 검증이 필요합니다.
준비한 설정 파일로 각 LLM 제품에 실제 로그인하여 호출하는 시험은 별도로 남아 있습니다. MCP 자체 연결은 공식 SDK 클라이언트와 실제 표준입출력 클라이언트로 검증했습니다.

구현 위치:

- [Sources/KakaoCore/Accessibility.swift](Sources/KakaoCore/Accessibility.swift): 앱 상태와 접근성 트리
- [Sources/KakaoCore/Conversations.swift](Sources/KakaoCore/Conversations.swift): 열린 대화 선택과 텍스트 조회
- [Sources/KakaoCore/ChatOpening.swift](Sources/KakaoCore/ChatOpening.swift): 앱 검색 및 대화 자동 열기
- [Sources/KakaoCore/Sending.swift](Sources/KakaoCore/Sending.swift): 전송 제어, 안전장치, 로컬 잠금
- [Sources/KakaoMCP](Sources/KakaoMCP): 공식 SDK 기반 MCP 도구와 Mac 승인 창
- [Sources/KakaoTalkCLI](Sources/KakaoTalkCLI): 명령어와 출력 처리
- [Tests/KakaoCoreTests](Tests/KakaoCoreTests): 개인정보 없는 자동 테스트
- [Tests/KakaoMCPTests](Tests/KakaoMCPTests): MCP 연결과 승인 경로 테스트

프로젝트의 [Package.resolved](Package.resolved)를 유지하면 동일한 의존성 버전으로 빌드할 수 있습니다.

## 라이선스

이 프로젝트는 [MIT 라이선스](LICENSE)로 배포합니다. 사용·수정·상업적 이용·재배포 시 저작권 고지와 라이선스 문구를 유지해야 합니다.
외부 의존성에는 각 프로젝트의 라이선스가 별도로 적용됩니다.