<!-- 本檔是本專案唯一規則檔；CLAUDE.md 是指向本檔的 symlink。
     裁減／最佳化時只刪過期或重複內容，不得刪除任一工具專屬規則。 -->

# AGENTS.md — Codenotch（khih）

全域規則見 `~/.codex/AGENTS.md`。quota 安全不變量以外層 `../AGENTS.md` §2–§4 為準；
Rust app 完全退役後才搬入本檔，現在不要複製或改寫它們。
優先順序：system／developer／使用者最新明確指令 > 本檔 > 全域規則。

## 1. 範圍與工作方式

- `khih/` 與外層 `codex-quota-keeper/` 是兩個獨立 git repo。
- Swift／SwiftUI + AppKit，fork 自 `vinzdg/codenotch`；`CONTRIBUTING.md` 是 upstream 檔，不改。
- 目標是移植 Rust quota 引擎，使 Codenotch 可取代 Rust app；**維持 Codenotch 原有 UI/UX 是硬需求**。
- 原計畫：`~/.claude/plans/giggly-nibbling-summit.md`。階段依序驗收；歷史計畫的雙 ring
  方案已被本次使用者決策取代，不得照舊計畫改回。
- git 由使用者處理：不得代為 commit 或改 history。不要將工作區未提交的功能寫成已 commit。
- 規則檔只收反覆出現、可歸因、窄改動可避免的問題；一次性的編譯拼字錯誤不增列制度。
- 改規則前先 `ls -la AGENTS.md CLAUDE.md`；維持 `CLAUDE.md -> AGENTS.md`。
  大改未追蹤／不乾淨檔案前先備份；本檔維持 250 行內。

## 2. 架構與承重檔案

`UsageProvider` 是純唯讀觀測者；會送請求的 quota 引擎獨立一層，在 `AppDelegate` 接線。
不得把 poke 偷塞進 provider 的重新整理，也不得用 UI 百分比替代引擎證據。

| 檔案（未註明者在 `Sources/Quota/`） | 職責 |
|---|---|
| `QuotaDomain.swift` / `QuotaState.swift` | 純安全邏輯、Int64 window、state v2、burn-rate／deadline |
| `QuotaStorage.swift` | accounts／settings、atomic write、check.lock、activity |
| `QuotaEngine.swift` | check／5h／共用 verifyPoke |
| `AntigravityEngine.swift` | 兩群組 transaction，各組獨立結果與狀態 |
| `QuotaController.swift` | MainActor 門面、忙碌限制、登入、通知、排程與取樣 |
| `QuotaProcess.swift` / `QuotaCancellation.swift` | 子程序、雙 pipe 排乾、timeout、取消 |
| `CodexAppServer.swift` | NDJSON JSON-RPC、device auth、fingerprint |
| `ClaudeUsage.swift` / `ClaudeBackend.swift` | Claude parser、身分、usage／poke、429 |
| `AntigravityUsage.swift` / `AntigravityBackend.swift` | 官方 agy TSV parser、共用序列化 client、固定請求 |
| `Providers/AntigravityCLIProvider.swift` | agy 唯讀 provider，來源 ID 為 gemini |
| `QuotaBurnReading.swift` | 引擎樣本轉顯示資料；不影響 poke |
| `QuotaSchedule.swift` / `FiveHourScheduleSection.swift` | 單次預約狀態機與設定 UI |
| `AddAccountSection.swift` / `FiveHourControls.swift` / `CheckOutcomeCopy.swift` | 登入、5h／立即檢查、結果文案 |
| `Model/ProviderOrder.swift` / `Model/UsageStore.swift` | 合併顯示、來源增補、輪詢、過期與讀值 |
| `Providers/CodexActiveAccount.swift` / `Providers/ProviderFamily.swift` | 判定目前登入的 Codex 帳號；設定頁公司分組 |

Upstream 合併接點：`App/AppDelegate.swift`、`Settings/SettingsView.swift`、
`Providers/CodexProfile.swift`、`Notch/NotchWindowController.swift`、`App/StatusItemController.swift`。

## 3. Swift quota 安全契約

- 引擎時間一律 `Int64` epoch seconds；只在 UI／格式化邊界轉 `Date`。
  不得重用含 Date／fraction 的 `LimitWindow` 解析 Claude 或 Antigravity usage。
- `countdownWindowActive()` 第 6 步固定為
  `observedAt - (resetsAt - duration*60) >= 2`，不得寫成 `> 0`。
  實機未啟動 window 的反推起點會跟著 observation 移動，不能因 reset time 存在就判定啟動。
- poke 成功後先 atomic 保存適用 reset key 與 `lastPoke.status = unverified`，再共用 `verifyPoke`。
  程序 exit 0／SUCCESS／OK 都不是已啟動證據；不另造一套寬鬆驗證。
- state／settings 用語意 round-trip，比較解碼值而非 byte-diff。
  Rust Option 的 `null` 與 Swift 省略 key 都可解碼；先前已實機確認 Swift 重寫後 Rust 能讀。
- 百分比超出 0–100 整次拒絕，不 clamp；時間戳截斷不四捨五入，秒／毫秒以 `> 1e11` 判別。
- Claude weekly 首次缺席只保存 pending，不得 poke，手動亦同；再次缺席且既有預定 reset 已過
  才可走 transaction。Swift 曾漏移這段，修改前對照 Rust `check_account()`，保留回歸測試。
- 身分未確認不得送出 Codex／Claude 請求。429 冷卻內不可碰身分或 usage backend，5h 亦不得繞過。
  `Retry-After: 0` 視為無指引，退回 15 分鐘；每次 HTTP request 都驗 User-Agent。
- 子程序解析使用 `Lazily<Value>`；不可在 init 預設參數或主執行緒提前跑 `claude --version`。
- `.live` 才是週守護；`.manual` 保留所有安全閘門、不發系統通知；`.observe` 只更新 baseline／
  burn-rate，不進 poke transaction。守護關閉時的自動取樣走 `.observe`，不是偷偷改成 `.live`。
- 檢查、5h、登入與預約共用 controller 忙碌限制；transaction 保留每帳號 `check.lock`。
  UI 不吞 `try?` 錯誤：`checkResults`／`FiveHourResult` 必須能辨識失敗、冷卻、忙碌與驗證結果。

## 4. 已決策的 UI／多帳號契約

- **Antigravity 一個 ring；Codex 多帳號合成一個 ring；展開沿用 tooltip 分組明細。**
  使用者 2026-09-10 明確選定的方向，不再把帳號／群組數量直接當成 ring 數量。
- 帳號仍各自擁有 provider、設定列、開關、憑證、baseline、lock 與 quota state；只合併顯示。
- 來源 ID 固定：Codex `codex-<id>`、Claude `claude`、Antigravity `gemini`，不可改為 `antigravity`。
  Codex 合併 cell 為 `codex:accounts`，不把這個顯示 ID 寫回帳號或當成 backend ID。
- 合併使用 `ProviderOrder.cells`；多來源用 `sourceProviderIDs`／`refreshProviderIDs`。
  重新整理、spinner、session activity 要涵蓋所有來源；各 window ID 加來源前綴，不能撞名。
- 合併函式須冪等：store 與 notch 都可能呼叫，不得把已合併 cell 再合併或重複展開。
- 主數字／ring 一律顯示**5 小時剩餘**，不加總／平均不同帳號的百分比。
  「剩餘最少的 window」只在找不到 5h window 時當退路——週視窗有七天可以填滿，
  永遠贏過剛重置的 5h，會讓 ring 答非所問。tooltip bar 仍填「已使用」，是已確認行為。
  Antigravity 固定取 `antigravity:gemini:five-hour`；Codex 取**目前登入帳號**的 5h。
- 目前登入的 Codex 帳號＝`~/.codex`（或 `CODEX_HOME`）與各帳號 `auth.json` 指紋相符者，
  用既有 `CodexFingerprint.of(codexHome:)`，不另寫 hash。比對不到時退回第一個有 5h 的帳號。
  以 `auth.json` mtime 當快取鍵（切換工具是整檔覆寫），並在 `UsageStore.tick()` 重算，
  否則沒有新讀值時 ring 不會跟著換。合併明細在該組標題加「使用中」標記。
- `~/.codex` 預設 profile **不列入**卡片與設定頁：它裝的就是目前登入的帳號，
  通常等於某個已管理帳號，列出來會同一帳號出現兩次。只在完全沒有 managed 帳號時保留，
  否則全新安裝會沒有 Codex ring。
- Claude 卡片不顯示即時工作階段清單：它的 monitor 以「行程存活」判定，idle 也常駐，
  而 Codex 需「8 秒內有寫檔」，同一張卡片會因 provider 而長成兩種樣子。
  過濾點在 `NotchViewModel.activity(for:)` 單一處，五個算 `sessionCount` 的地方才會一致。
  Claude 額度列名稱與其他家對齊（`5h limit`／`Weekly limit`），但視窗 id 仍是 `session`／
  `weekly_all`（`headlineID` 靠它），且 `ClaudeUsageCLI` 解析的 `Current session:` 是
  Claude CLI 的輸出格式，不是我們的文案，不可改。
- 左鍵點展開卡片＝對該卡片的帳號執行 `.manual` 立即檢查（逐一 await，不並行）；
  結果用 `CheckSummaryCopy.line` 收斂成一行顯示在卡片內。**「啟動 5 小時倒數」不放進左鍵**，
  維持只在右鍵子選單，保留「刻意的第二步」。點卡片以外的區域仍是釘住。
- **瀏海每個螢幕一個 `NotchWindowController`**，所以 controller 自己的「一次只跑一個」擋不住
  第二個螢幕，逐帳號的 `isRunning(_:)` 也只回答被問到的那一個。任何會送請求的動作都要再看
  `QuotaController.isBusy` 這個引擎層旗標，否則外接螢幕點兩次就 fan-out 兩輪。
- 設定頁「已連線」依 `ProviderFamily` 分 Section；分組只做在呈現層，
  底層順序仍是扁平陣列（拖曳排序直接操作它）。跨組拖曳回傳 false。
- `SettingsView.quota` 是普通 `var` 而非 `@ObservedObject`，`.onChange(of: quota.…)` **不會觸發**；
  要即時更新就從已觀察該物件的子 view 往上回呼（`AddCodexAccountSection.onAdded`）。
  列表本身是 `@State` 快照，而 `providerSummaries` 會逐 provider 讀 Keychain——
  不可把它綁在輪詢上重取，否則 macOS 會反覆跳授權提示。
- 讀取失敗的帳號不可從明細消失；保留既有讀值並揭示過期／錯誤，不把 unknown 填成 0%。
- Ollama 多模型仍沿用 `notchSnapshots` + `sourceProviderID`；不要為這次合併重寫其結構。
- 新登入成功經 fingerprint 去重後，呼叫 `onAccountsChanged`：重新探索 profiles，
  `UsageStore.addProviders` 只增補新 ID，接上新 monitor／5h 清單；不重建 store、不要求重啟。
- 取消／逾時／登入程序建立失敗必須完成清理後才回報；不可 fire-and-forget 清理，否則下一次
  登入或測試會讀到孤兒帳號。重複登入不觸發新增 provider／monitor。
- UI 進行中回饋沿用 `UsageStore.refreshing` 與手動 refresh 的 380ms 最短回饋。
- 文案走 `L10n.t` 的英文 literal key，繁中 locale 是 **`zh-Hant-TW`**；不要用 `zh-Hant`。
  插值 key 中字串為 `%@`，字面百分號要 `%%`，例如 `Full 5h ≈ %@%% weekly`。
- `Localizable.xcstrings` key 為插入序，新 key 只 append；驗證既有 key 內容與順序未變。
  append 前先查 key 是否已存在（例：`Checking…` 早有「正在檢查…」），沿用既有翻譯不要另立說法。
  不為加翻譯重排整檔。對新增插值文案加繁中斷言，並目視渲染，避免英文悄悄 fallback。
- tooltip 新增資訊時同步調整 `NotchLayout.cardHeight` 與所有 hover／panel 計算，
  使用匿名三帳號 fixture 驗證完整六個 window，不只確認 image 非空。

## 5. Antigravity、子程序與排程

- 額度唯一來源：官方 `agy -p /usage --output-format json` 成功 envelope 的 TSV。
  只接受 Gemini 與 Claude／GPT 兩組、各 5h／weekly；缺列、重複、非法百分比／時間整次拒絕。
- CLI 依環境變數 `CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN`、`~/.local/bin/agy`、PATH 延後解析。
  登入由官方 CLI 管理，不恢復 token／OMP SQLite／bridge 讀取路徑。
- 自動讀取間隔 300 秒；CLI timeout 130 秒、provider deadline 140 秒。
  同來源僅一個程序；`AntigravityClient` 在觀測者與引擎間共享序列化，verification 必須重新讀取。
- Gemini → Claude／GPT 順序固定；每組只送一次核准的最小請求、不重試。
  單組失敗仍處理下一組；5h 已啟動則略過。狀態存在 `antigravityGroups.{gemini,claude_gpt}`，
  UI／通知逐組回報；不得以一組成功掩蓋另一組失敗。
- `QuotaProcess` 用 nonblocking read 公平排乾 stdout／stderr；不要順序呼叫 blocking
  `availableData`，安靜程序或單邊滿 pipe 都會讓 timeout 失效。
  timeout／取消先 TERM，grace 後 KILL 並 wait；結束 App 時要傳遞 cancellation。
- 長 transaction 可能超過 600 秒 stale-lock 門檻；持鎖期間以 heartbeat 更新同一 inode 的 mtime，
  不可讓仍存活的 transaction 被另一個程序當成 stale。保留 heartbeat 測試。
- burn-rate 使用 reconciled 引擎樣本；每群組獨立，樣本不足、unknown、過期必須明說。
  `UsagePace.swift`、舊 tooltip pace 與 preference key 已移除，不恢復舊估算路徑。
- 單次全域預約：`settings.json` version 1／`fiveHourStartAt`，台灣時間 UI、Int64 引擎。
  每秒只看記憶體；到點忙碌保留，**超過** 3600 秒取消，恰好一小時仍可執行。
- 可執行時先成功 atomic 清空再啟動；儲存失敗不送請求。啟動與運行期間都檢查，App 未執行／
  睡眠時不執行，不建立 LaunchAgent。到點依序處理當時啟用帳號，拒絕亦寫「預約觸發」activity。

## 6. Build、測試與診斷

```sh
make gen       # 新增 Swift 檔必須；build／test 已包含
make test-ci   # 本機 make test 會選到 Apple Development 簽章而失敗
make build DEV_SIGN='CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'
make build-ci  # 唯一能產出「可實際啟動」的 ad-hoc Release App
```

- `make build` 出來的是 **Debug**，程式碼在 `Codenotch.debug.dylib` 而不是主執行檔——
  用 `nm` 驗新符號時挑錯檔案會得到「新程式碼不在裡面」的假結論。`make archive` 需要
  Developer ID。要一份能雙擊執行的就用 `make build-ci`：它多帶
  `disable-library-validation` entitlement，否則 ad-hoc 簽章會讓 dyld 在啟動時擋下
  Sparkle（`codesign --verify` 照樣通過，只有真的啟動才看得出來）。
- 本機同時存在多份同 bundle ID 的 `Codenotch.app`。**啟動一律用完整路徑**，不要靠 App 名稱；
  `ls -dt` 會挑錯 DerivedData 目錄，以 build log 裡印出的實際輸出路徑為準。
- 確認某個 build 真的含新程式碼，兩件一起看：`nm <對的 binary>` 找型別名，加上
  `plutil -p <app>/Contents/Resources/zh-Hant-TW.lproj/Localizable.strings` 找新文案。
- `.xcodeproj` 由 `project.yml` 生成、不進 git；首次 build 可能需網路下載 Sparkle／SwiftNIO。
- XCTest 只用固定時間、匿名 JSON、fake executable／backend／HTTP listener、暫存資料與隔離 defaults；
  不得讓測試碰真實 Keychain、登入或 quota。App 的 XCTest launch guard 必須保留。
- fixture 必須帶上被測邏輯真正讀的欄位。`LimitWindow` 少了 `duration`，依 duration 選 headline
  的規則會**靜默走退路**——測試照樣綠燈，卻什麼都沒驗到。
- 移除功能前 `rg` 所有 source／test 參照；只移除該功能斷言，保留 parser 等仍有效的測試。
- EdgeArrival／EdgeCrossfade 曾間歇失敗：在乾淨 HEAD 的獨立 worktree／DerivedData 跑同組比對。
  HEAD 通過不能宣稱「已證明是環境」；修正後完整重跑並如實記錄，不放寬斷言求過關。
  用完以 `git worktree remove` 收掉，直接刪目錄會留下壞掉的 git 中繼資料。
- 輸出渲染圖給 Xcode test host：`TEST_RUNNER_GROUPED_RENDER_DIR=<tmp>`，
  只設外層 `GROUPED_RENDER_DIR` 不一定會傳入。相關測試為 `GroupedTooltipRenderTests`。
- 證據一律**重跑取得**，本檔不要引用 `/tmp` 路徑：會被清掉，引用過時 log 比沒有更糟。
- AX 失效／screenshot unavailable 不能當成介面驗收成功；程式測試、渲染、實機驗收分開回報。
  AX 一路回傳失效元素時改走 `CGWindowListCopyWindowInfo` 找 window ID 再 `screencapture -l<ID>`；
  但 notch 收合時視窗幾乎全透明（實測 642×2654 僅約 1300 個不透明像素），不 hover 拍不到 ring。
  不能 hover 就把該項交使用者看，不要拿空截圖當通過。
- BSD sed 不支援 `\b`；word-boundary 替換用 Python `re.sub`。

## 7. 資料與實機操作禁區

- 共用資料目錄：`~/Library/Application Support/codex-quota-keeper/`；保留既有 baseline／fingerprint。
- 診斷或啟動前先 `pgrep -x Codenotch`、`pgrep -x codex-quota-keeper`；兩 App 不得同時執行。
  不得擅自關閉既有 App；已取得的明確重啟授權可沿用，不重複問同一動作。
- **關閉週守護不等於完全不會送請求**：手動 5h／立即檢查與已存單次預約仍有主動路徑。
  唯讀驗收前檢查是否有現存預約；不要操作這些按鈕。`-quotaKeeperEnabled NO` 僅為本次啟動覆寫，
  不代表持久化偏好已關閉——本機 `defaults read com.vinz.codenotch quotaKeeperEnabled` 目前是
  **1（守護開啟）**，所以不帶旗標啟動就是守護狀態。每次啟動前重新核對，不要憑印象。
- 開啟守護可能在 weekly 0% reset 時送出請求，包含 Claude／Antigravity；
  不得把當下 weekly 非 0 當成設計保證。真實 poke 另需明確同意，首次 Claude／Antigravity 尤其如此。
- live read 沿外層診斷規則；Antigravity 真實讀取只由 App 執行官方 CLI。
- token、auth.json、完整帳號 ID、email、fingerprint、私人狀態不得進 repo 或外部服務；
  規則檔／commit message 不記帳號 label，驗收僅輸出去識別的必要資料。
- 讀系統 `~/.codex/auth.json`（`CodexActiveAccount`）只取 `tokens.account_id` 算指紋即丟；
  同檔的 token 不得讀出、記錄或存檔。App 未開 App Sandbox（`project.yml` 有註解說明原因），
  讀得到不代表可以讀更多。
- 更換模型、prompt、安全旗標或放寬重送次數需明確同意；固定值以外層規則為準。
- Rust 退役須全部驗收通過，再盤點實際 App／啟動入口，列具體清單供確認；
  舊 App／資料移入 `mktemp -d` 備份，不用 `rm -rf`，共用資料目錄保留。

## 8. 進度與續作入口（2026-09-10）

HEAD `7e4b62b`；**全部修改尚未 commit**，`AGENTS.md`／`CLAUDE.md` 仍未追蹤，交由使用者納入 git。
最新完整驗證：**1201 tests、1 skipped、0 failures**、ad-hoc build、`git diff --check` 通過；
`Localizable.xcstrings` 459 keys，既有 key 順序與內容以程式比對確認未變。
可執行 App 已部署在 `build/Codenotch.app`（Release、ad-hoc、universal、無 `get-task-allow`）；
`/Applications` 的舊安裝版與舊建置快取已移入 `mktemp -d` 備份後清除。

第一輪（Rust 引擎移植、單 ring、帳號即時更新、立即檢查、burn-rate／預約／選單）以 fake
provider 測試與繁中渲染測試涵蓋，均通過。第二輪為使用者實機回報的六項：

| 第二輪回報 | 處置 |
|---|---|
| Claude 展開頁多餘工作階段 | `activity(for:)` 對 Claude 回 nil；額度列改名 5h／每週 |
| Codex ring 取最低而非目前帳號 | 新 `CodexActiveAccount` 指紋比對，headline 取該帳號 5h |
| Antigravity ring 顯示週額度 | headline 固定 `antigravity:gemini:five-hour` |
| 卡片不能點 | 左鍵＝`.manual` 立即檢查＋卡內一行結果；5h 仍只在右鍵 |
| 新增帳號未即時出現在設定頁 | `AddCodexAccountSection.onAdded` → `refreshVisibleState()` |
| 已連線帳號未分組 | 新 `ProviderFamily`，設定頁逐公司 Section，跨組拖曳拒絕 |

順帶：`~/.codex` 預設 profile 不再列為第五個 Codex 帳號（詳見 §4）。

**尚未完成，續作從這裡開始：**

| 項目 | 狀態 |
|---|---|
| 六項的實機驗收 | ring 數字、「使用中」標記、點卡片檢查、設定頁分組與即時更新，全部未驗 |
| 卡片外觀驗收 | light mode、高對比、reduce motion／transparency、idle CPU |
| lifecycle 驗收 | 睡眠喚醒、真實取消／timeout；使用者已明確擱置 |
| 真實 poke | 未送過；首次 Claude／Antigravity 需明確同意 |
| Rust 退役 | **不可宣告可退役**；未搬外層安全規則 |

渲染圖已目視：Claude 卡片只剩兩列額度＋burn-rate 行；Codex 合併卡三組完整，
「· 使用中」標題單行不換行。**渲染通過不等於實機通過**——續作先核對執行版本與授權再驗收。
