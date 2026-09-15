<!-- 本檔是本專案唯一規則檔；CLAUDE.md 是指向本檔的 symlink。
     裁減／最佳化時只刪過期或重複內容，不得刪除任一工具專屬規則。 -->

# AGENTS.md — Codenotch（khih）

全域規則見 `~/.codex/AGENTS.md`。quota 安全不變量以外層 `../AGENTS.md` §2–§4 為準；
Rust app 完全退役後才搬入本檔，現在不要複製或改寫它們。
優先順序：system／developer／使用者最新明確指令 > 本檔 > 全域規則。

## 1. 範圍與工作方式

- `khih/` 與外層 `codex-quota-keeper/` 是兩個獨立 git repo。Swift／SwiftUI + AppKit，fork 自
  `vinzdg/codenotch`；`CONTRIBUTING.md` 是 upstream 檔，不改。目標是移植 Rust quota 引擎，使 Codenotch
  可取代 Rust app；**維持 Codenotch 原有 UI/UX 是硬需求**。
- git 由使用者處理：不得代為 commit 或改 history。不要將工作區未提交的功能寫成已 commit。
- 回報改動規模或提議 commit 前先 `git status --short` 看**整個 repo**，不要只看自己編輯的檔案就報數字；
  審查工具只看 tracked diff，未追蹤新檔會被誤報成「型別未定義、編不過」，先查 `git status` 再信。
- 改規則前先 `ls -la AGENTS.md CLAUDE.md` 維持 `CLAUDE.md -> AGENTS.md`；大改未追蹤／不乾淨檔案前先
  備份，本檔維持 250 行內（收錄門檻見全域規則）。

## 2. 架構與承重檔案

`UsageProvider` 是純唯讀觀測者；會送請求的 quota 引擎獨立一層，在 `AppDelegate` 接線。
不得把 poke 偷塞進 provider 的重新整理，也不得用 UI 百分比替代引擎證據。
| 檔案（未註明者在 `Sources/Quota/`） | 職責 |
|---|---|
| `QuotaDomain.swift` / `QuotaState.swift` | 純安全邏輯、Int64 window、state v2、burn-rate／deadline |
| `QuotaStorage.swift` | accounts／settings、atomic write、check.lock recovery／heartbeat、activity |
| `QuotaEngine.swift` / `AntigravityEngine.swift` | check／5h／共用 verifyPoke；兩群組 transaction 各組獨立 |
| `QuotaController.swift` / `QuotaSchedule.swift` | MainActor 門面、忙碌限制、登入、通知、排程與取樣 |
| `QuotaProcess.swift` / `QuotaCancellation.swift` / `BackgroundCLI.swift` | 子程序、pipe、取消與禁止背景開啟瀏覽器 |
| `CodexAppServer.swift` / `ClaudeUsage.swift` / `ClaudeBackend.swift` | NDJSON JSON-RPC、device auth；Claude parser、身分、usage／poke、429 |
| `AntigravityUsage.swift` / `AntigravityBackend.swift` / provider | agy parser、序列化 client；來源 ID gemini |
| `QuotaBurnReading.swift` / `Model/UsageStore.swift` | 引擎樣本、burn reading 與顯示發布；不影響 poke |
| `Model/ProviderOrder.swift` / `CodexActiveAccount.swift` / `KeychainAccess.swift` / `ClaudeCredentials.swift` | 多來源合併、目前帳號、window ID／headline；序列化 Security 存取與共用快取 |
| `Features/ProviderRing.swift` / `QuotaDetailDisplay.swift` / `FiveHourScheduleSection.swift` / `AddAccountSection.swift` | 點擊／等待動畫、詳細頁呈現、預約／登入／5h 文案 |
Upstream 合併接點：`App/AppDelegate.swift`、`Settings/SettingsView.swift`、`Providers/CodexProfile.swift`、`Notch/NotchWindowController.swift`、`App/StatusItemController.swift`。

## 3. Swift quota 安全契約

- 引擎時間一律 `Int64` epoch seconds，只在 UI／格式化邊界轉 `Date`；不得重用含 Date／fraction 的 `LimitWindow` 解析 usage。
- `countdownWindowActive()` 第 6 步固定為 `observedAt - (resetsAt - duration*60) >= 2`，不得寫成 `> 0`：
  實機未啟動 window 的反推起點會跟著 observation 移動，不能因 reset time 存在就判定啟動。
- poke 成功後先 atomic 保存適用 reset key 與 `lastPoke.status = unverified`，再共用 `verifyPoke`。
  程序 exit 0／SUCCESS／OK 都不是已啟動證據；不另造一套寬鬆驗證。
- state／settings 用語意 round-trip，比較解碼值而非 byte-diff（Rust Option 的 `null` 與 Swift 省略 key 都可
  解碼，已實機確認 Rust 能讀）。百分比超出 0–100 整次拒絕不 clamp；時間戳截斷不四捨五入，秒／毫秒以 `> 1e11` 判別。
- Claude weekly 首次缺席只保存 pending，不得 poke，手動亦同；再次缺席且既有預定 reset 已過
  才可走 transaction。Swift 曾漏移這段，修改前對照 Rust `check_account()`，保留回歸測試。
- 身分未確認不得送出 Codex／Claude 請求。429 冷卻內不可碰身分或 usage backend，5h 亦不得繞過；
  `Retry-After: 0` 視為無指引退回 15 分鐘，每次 HTTP request 都驗 User-Agent。子程序解析用
  `Lazily<Value>`，不可在 init 預設參數或主執行緒提前跑 `claude --version`。
- `.live` 才是週守護；`.manual` 保留所有安全閘門、不發系統通知；`.observe` 只更新 baseline／
  burn-rate，不進 poke transaction。守護關閉時的自動取樣走 `.observe`，不是偷偷改成 `.live`。
- 檢查、5h、登入與預約共用 controller 忙碌限制；transaction 保留每帳號 `check.lock`。
  UI 不吞 `try?` 錯誤：`checkResults`／`FiveHourResult` 必須能辨識失敗、冷卻、忙碌與驗證結果。
- stale lock 回收須持有 `check.lock.recovery` 的 `flock`；釋放前比對 descriptor／路徑 inode，
  不可用 stat→unlink→create 的 TOCTOU 流程。帳號清理須先成功保存 `accounts.json` 才刪目錄並向 UI 回錯。

## 4. 已決策的 UI／多帳號契約

- **Antigravity 一個 ring；Codex 多帳號合成一個 ring，tooltip 分組明細**；帳號／群組數不等於 ring 數。
  帳號仍各自擁有 provider、設定列、開關、憑證、baseline、lock 與 quota state，只合併顯示。
- 來源 ID 固定：Codex `codex-<id>`、Claude `claude`、Antigravity `gemini`，不可改為 `antigravity`；
  Codex 合併 cell 為 `codex:accounts`，不把這個顯示 ID 寫回帳號或當成 backend ID。
- 合併使用 `ProviderOrder.cells`，多來源用 `sourceProviderIDs`／`refreshProviderIDs`；重新整理、
  spinner、session activity 要涵蓋所有來源，各 window ID 加來源前綴不能撞名。合併函式須冪等：store 與
  notch 都可能呼叫，不得把已合併 cell 再合併或重複展開。Ollama 多模型沿用既有 `notchSnapshots` 結構。
- 主數字／ring 一律顯示**5 小時剩餘**，不加總／平均不同帳號的百分比；「剩餘最少的 window」只在找不到
  5h 時當退路，不得拿週額度搶走 headline。Antigravity 取 `antigravity:gemini:five-hour`，缺席時退回
  weekly（免費方案現況）；Codex 取**目前登入帳號**的 5h。
- 目前登入的 Codex 帳號＝`~/.codex`（或 `CODEX_HOME`）與各帳號 `auth.json` 指紋相符者，用既有
  `CodexFingerprint.of(codexHome:)`，不另寫 hash；比對不到退回第一個有 5h 的帳號。以 `auth.json` mtime 當
  快取鍵並在 `UsageStore.tick()` 重算，否則沒有新讀值時 ring 不會換。該組以 **accent 色框線**標示（已實機確認）
  （`LimitWindow.isActiveAccount` → `TooltipWindowGroup`）而非文字；色彩不可是唯一訊號，`accessibilityLabel` 仍要唸出「In use」。
- 有 managed 帳號時，卡片／設定頁不列 `~/.codex` 預設 profile，避免重複；無 managed 帳號才保留。
- Claude 的存活行程不代表工作中，卡片不顯示即時工作階段；統一在 `NotchViewModel.activity(for:)` 過濾，
  不在各 sessionCount 分散判斷。額度列名稱與其他家對齊（`5h limit`／`Weekly limit`），但視窗 id 仍是
  `session`／`weekly_all`（`headlineID` 靠它）；`ClaudeUsageCLI` 的 `Current session:` 是 Claude CLI 的輸出格式，不是我們的文案。
- 三家受管理 ring 左鍵＝展開詳細頁並 `.manual` 立即檢查；Codex 按顯示順序逐帳號 await，
  Antigravity 仍逐群組保存結果。`QuotaController.checkBatch` 整批維持 busy，不能只鎖單帳號。
  每個螢幕各有 controller；連點／跨螢幕需看引擎 `isBusy`，忙碌不另發重新讀取。
- **Codex 群組左鍵＝只對該帳號 `startFiveHour`**（取代舊「左鍵不可啟動 5h」限制）；右鍵 5h 保留，非
  Codex 卡片沿用立即檢查，卡片外空白仍釘住，群組間空白不送請求。識別依據是 `TooltipWindowGroup`／
  `groupID`／`sourceProviderID`，不能用名稱或陣列位置。命中區取自繪圖實際 frame；標題＋額度框共用點擊區，結果顯示於該組。
- 左鍵由 `NotchPanel.sendEvent` 統一路由；SwiftUI／輔助使用共用動作，避免一次按下執行兩次。保留設定
  按鈕、釘住與 Option 拖曳。`detailsOnClick` 預設 true（懸停不開，關閉該選項才恢復 hover）；
  `detailsShowRemaining` 預設 false，只切詳細頁 bar＋百分比，不改 ring、警告色或引擎證據。兩選項皆保存。
- 設定視窗可暫時升為 `.regular`，關閉後必須 `.accessory`，不能因偏好 `.dock` 留在 Dock；
  `SettingsPanel.miniaturize` 走 `performClose`，不留縮圖且保留登入清理閘門，App 與 ring 繼續執行。
  「已連線」依 `ProviderFamily` 分 Section，分組只做在呈現層，底層仍是扁平陣列（拖曳排序直接操作它），跨組拖曳回傳 false。
- `SettingsView.quota` 是普通 `var` 而非 `@ObservedObject`，`.onChange(of: quota.…)` **不會觸發**；
  要即時更新就從已觀察該物件的子 view 往上回呼（`AddCodexAccountSection.onAdded`）。
  列表是 `@State` 快照；帳號摘要不得為顯示方案名稱載入秘密憑證，也不綁輪詢反覆重建。
- 讀取失敗的帳號不可從明細消失；保留既有讀值並揭示過期／錯誤，不把 unknown 填成 0%。
- 過期 reset 只有最新讀值可顯示「重置中」；stale 且正在讀取顯示 `Checking…`，失敗顯示
  `The reading is out of date.`。manual check 以 `QuotaController.onQuotaSnapshot` 將引擎已讀 snapshot
  發布給 `UsageStore`，不可完成後再 `store.refresh` 重讀同一來源；轉換須保留三家 window ID／headline。
- **同一份顯示轉換只能有一處**：Antigravity 視窗走 `AntigravityCLIProvider.windows(from:)`，headline 走各家
  `*Usage.headlineID(in:)`；provider 輪詢與引擎 `publishQuotaSnapshot` 呼叫同一份，就地重寫會讓同一張卡片
  因上次由誰更新而換 headline。視窗 id `"<limitId>:<five-hour|weekly>"` 被 `withBurnReadings` 字面比對綁死。
  `AntigravityGroup.window(in:weekly:)` 是**引擎閘門**（唯一 bucket／duration），不可拿來當 UI 建構。
- `QuotaController` 兩處手抄的「哪些 outcome 帶新讀值」白名單**不可用「`observedAt` 是否前進」取代**：
  引擎側等價，破功的是呼叫端——session 首次呼叫沒有比較基準，會把磁碟舊 snapshot 當新讀值發布成 `.ok`；
  且每螢幕各有 controller、進度互不相通，而 `UsageStore` 守衛是 `>=` 會放行重發。唯一解是 §8 已排的
  「引擎回傳 persisted snapshot」（動 65 個測試呼叫點），不是清理範圍。
- 速度目標是正常路徑約 2 秒與立即誠實回饋，不是硬砍安全 timeout。Codex quota／profile enrichment 可
  平行；Claude CLI fallback、Antigravity 共用序列化 client、poke verification 不為速度放寬。
- 新登入成功經 fingerprint 去重後呼叫 `onAccountsChanged`：重新探索 profiles，`UsageStore.addProviders`
  只增補新 ID，接上新 monitor／5h 清單，不重建 store、不要求重啟。新增 Codex 走設定視窗的原生 sheet
  （命名→瀏覽器登入→完成，代碼可選取／複製）：失敗保留名稱供重試，重複登入明說未新增，取消／Escape／
  關閉／逾時都須等程序與暫存帳號清理後才結束或接受下一次登入。
- 點擊手感與 backend 等待分開：縮入 0.93 倍、380ms 後釋放，保留有限旋轉／spring；等待短弧用獨立
  `TimelineView` 持續轉、完成即停。額度變化／旋轉／縮放各自限定動畫範圍，Reduce Motion 靜態提示；共享
  回饋沿用 `UsageStore.refreshing`，frame 未變不要 `setFrame`。
- 文案走 `L10n.t` 的英文 literal key，繁中 locale 是 **`zh-Hant-TW`**（不要用 `zh-Hant`）；插值為 `%@`，
  字面百分號要 `%%`（例：`Full 5h ≈ %@%% weekly`）。`Localizable.xcstrings` key 為插入序，新 key 只
  append 且先查是否已存在（例：`Checking…` 早有「正在檢查…」），沿用既有翻譯、不重排整檔；驗證既有 key
  內容與順序未變，新增插值文案加繁中斷言並目視渲染，避免英文悄悄 fallback。
- tooltip 新增資訊時同步調整 `NotchLayout.cardHeight` 與所有 hover／panel 計算，用匿名三帳號 fixture 驗證完整六個 window。

## 5. Antigravity、子程序與排程

- 額度唯一來源：官方 `agy -p /usage --output-format json` 成功 envelope 的 TSV。只接受 Gemini 與
  Claude／GPT 兩組；weekly 必要，缺 weekly／重複／非法百分比／時間整次拒絕。**5h 視方案而定**，缺時
  primary 留空不得補 0%、路徑不得移除（2026-09-14 實測無訂閱時只有 weekly，續訂後會回來）。CLI 依環境
  變數 `CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN`、`~/.local/bin/agy`、PATH 延後解析；登入由官方 CLI 管理，
  不恢復 token／OMP SQLite／bridge 讀取路徑。
- **`-p`／stdin 非終端機不保證不會登入開網頁**。Antigravity read／poke 必須經 `BackgroundCLI`：
  sandbox 限制 open、osascript、.app 啟動、Apple Events、LaunchServices lsd，另設 `BROWSER=/usr/bin/false`。
  限制失敗不得退回直接執行；CLI stderr 可能含完整 OAuth URL，不可原樣寫 log／activity。
  登入只由使用者在官方 CLI 完成；fake launcher 阻擋通過不代表真實登入已恢復。
- Claude provider／引擎共用 `ClaudeKeychain.shared`；背景與 ring 禁止互動授權，只有設定頁
  明確按「允許存取」才允許該次操作。`KeychainAccess` 序列化 process-wide Security 旗標並恢復原值，
  其他 Keychain caller 也須經共用閘門；不可並行改全域旗標或用第二份 token cache 抵消輪替偵測。
- Claude 拒絕／過期保留原因與最後讀值；不可 `try?` 壓成 signed-out 或回退舊憑證檔。
  過期 token 不送 usage；401／403 清共用快取，不新增立即重試、不自行 refresh OAuth。
  `loadBackoffUntil` 回 nil 不分「已過期」與「從未設定」，判斷存在用 `hasBackoffUntil`。錯誤走
  `LocalizedError`＋L10n，分開存取拒絕／過期／登入拒絕／HTTP；官方登入過期仍需使用者更新，不承諾
  Always Allow 永久有效或修文案就恢復登入。
- 自動讀取間隔 300 秒；CLI timeout 130 秒、provider deadline 140 秒。同來源僅一個程序；`AntigravityClient` 在觀測者與引擎間共享序列化，verification 必須重新讀取。
- Gemini → Claude／GPT 順序固定；每組只送一次核准的最小請求、不重試，單組失敗仍處理下一組，5h 已啟動
  則略過。狀態存在 `antigravityGroups.{gemini,claude_gpt}`，UI／通知逐組回報，不得以一組成功掩蓋另一組失敗。
  每組每次檢查都寫 activity：讀值一行、結論一行（`QuotaEngine.activityLine(for:)`，措辭與 provider 路徑逐字
  相同），且寫在 `checkAntigravity` 呼叫端而非各分支內（否則新增分支會靜默）；`.observe` 只寫讀值。
- `QuotaProcess` 用 nonblocking read 公平排乾 stdout／stderr；順序呼叫 blocking `availableData` 會讓安靜
  程序或單邊滿 pipe 弄失效 timeout。以 `posix_spawn` 在 exec 前建立 process group，timeout／取消對整群
  TERM、grace 後 KILL 並 wait，`waitpid` 處理 EINTR；結束 App 傳遞 cancellation，測試須證明父子都退出。
- 長 transaction 可能超過 600 秒 stale-lock 門檻；持鎖期間以 heartbeat 更新同一 inode 的 mtime，不可讓
  仍存活的 transaction 被另一個程序當成 stale。保留 heartbeat 測試。
- burn-rate 使用 reconciled 引擎樣本；每群組獨立，樣本不足、unknown、過期必須明說。`UsagePace.swift`、
  舊 tooltip pace 與 preference key 已移除，不恢復舊估算路徑。
- **Claude 憑證失效時的讀取降級**（2026-09-15 使用者同意）：`QuotaEngine.readUsage()` 有憑證走 endpoint，
  沒有就走 `claude /usage`。收窄而非刪除「CLI 不得取代 backend time-series」的方式是**限定用途**：
  `checkAccount` 與 `verifyPoke` 可用（週守護因此不會斷），**`startFiveHour` 只接受 endpoint**——CLI 的
  reset 只印到分鐘，59 秒誤差對 7 天視窗無所謂，對 5h 的 60 秒歸因容忍值卻是致命的。帳號仍由
  `claude auth status` 確認（不需鑰匙圈），週閘門與 `pokeAttemptLimit` 原封不動，缺席視窗與 endpoint 一樣
  物化成 0%（否則兩來源對 rollover 的描述不一致）。429 不得用 CLI 繞過：同一個 bucket。
  降級讀取必須寫 activity；不得擴大到其他 provider。
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

- `make build` 出來的是 **Debug**，程式碼在 `Codenotch.debug.dylib` 而非主執行檔——`nm` 驗新符號時挑錯
  檔案會得到「新程式碼不在裡面」的假結論。`make archive` 需要 Developer ID；要能雙擊執行的用
  `make build-ci`，它多帶 `disable-library-validation`，否則 ad-hoc 簽章會讓 dyld 啟動時擋下 Sparkle
  （`codesign --verify` 照樣通過，只有真的啟動才看得出來）。
- 本機有多份同 bundle ID 的 `Codenotch.app`：**啟動一律用完整路徑**，以 build log 印出的輸出路徑為準
  （`ls -dt` 會挑錯 DerivedData）。Release 最佳化可能消除型別名，缺 symbol 不等於沒編入，須再核對
  可辨識的實作字串／產物 hash 與繁中 `Localizable.strings`。
- `.xcodeproj` 由 `project.yml` 生成、不進 git；首次 build 可能需下載 Sparkle／SwiftNIO。備份移出 Sources 掃描範圍後再 `make gen`，gen／build 不與檔案移動並行。
- `build/` 被 gitignore；`make clean` 刪整個 build，`make build-ci` 先刪 `build/ci`（**會刪掉正在執行的
  App bundle，重建前先關閉**）。產物不可宣稱已安裝；長期保留須複製到 `/Applications` 並先取得同意。
- XCTest 只用固定時間、匿名 JSON、fake executable／backend／HTTP listener、暫存資料與隔離 defaults；不得
  讓測試碰真實 Keychain、登入或 quota，App 的 XCTest launch guard 必須保留。fixture 必須帶上被測邏輯真正
  讀的欄位：`LimitWindow` 少了 `duration`，依 duration 選 headline 會**靜默走退路**——綠燈卻什麼都沒驗到。
  burn-rate 樣本要求前後兩筆 5h `resetsAt` 是**同一絕對時間**（不同＝換窗，`resetAtMoved` 直接跳過取樣）；
  固定回 0% 的 fake 會讓週守護重送到 `pokeAttemptLimit`＝3，斷言寫死 1 必失敗。
- 派審查 agent（/simplify、/code-review）必須預先給 skip list，否則 §3–§5 的安全不變量會被當成可合併或
  可平行化回報：三路徑各自閘門、Gemini→Claude/GPT 固定順序、序列化 client、手刻 process plumbing、
  fixture 刻意保留的欄位。基準測試數以重跑為準，`Tests/` 沒被改動就不可能因改 `Sources/` 而變動。
- 飄測試（EdgeArrival／EdgeCrossfade）用乾淨 HEAD 的獨立 worktree／DerivedData 比對，用完 `git worktree
  remove`；HEAD 通過不能宣稱「已證明是環境」，不放寬斷言求過關。
- 渲染環境用 `TEST_RUNNER_GROUPED_RENDER_DIR`／`TEST_RUNNER_RING_RENDER_DIR` 傳入 test host，單設外層同名
  變數不保證傳入；原生文字用 NSHostingView＋AppKit bitmap 與明確背景，ImageRenderer 的禁止符號／透明黑底
  圖不能當通過。互動驗收至少含四邊緣／兩縮放、三個同名匿名帳號六視窗、組間空白、連點／跨螢幕單飛，動畫
  要驗超過首圈後仍動、讀值中途更新與完成不殘留。
- 證據一律**重跑取得**，本檔不要引用 `/tmp` 路徑：會被清掉，引用過時 log 比沒有更糟。AX 失效／
  screenshot unavailable 不能當成介面驗收成功；程式測試、渲染、實機驗收分開回報。AX 一路失效改走
  `CGWindowListCopyWindowInfo` 找 window ID 再 `screencapture -l<ID>`；拍不到就交使用者看。
- **zsh 的 `log` 是內建指令**：一律寫 `/usr/bin/log`，否則靜默回空，會得到「App 沒輸出日誌」的假結論；
  test host 與 App 共用 subsystem，查執行中的 App 要加 `--predicate 'processIdentifier == <pid>'`。
  **驗證指令不可接 `head`／`tail`**：SIGPIPE 會把 `make test-ci` 一起殺掉並留下損毀的 xcresult（看起來像
  測試失敗），截斷也會吃掉測試總數；一律 `> 檔案 2>&1` 再 grep 全文。BSD sed 不支援 `\b`，改用 Python。

## 7. 資料與實機操作禁區

- 共用資料目錄：`~/Library/Application Support/codex-quota-keeper/`；保留既有 baseline／fingerprint。
  診斷或啟動前先 `pgrep -x Codenotch`、`pgrep -x codex-quota-keeper`，兩 App 不得同時執行；不得擅自
  關閉既有 App，已取得的明確重啟授權可沿用，不重複問同一動作。
- **關閉週守護不等於完全不會送請求**：手動 5h／立即檢查與已存單次預約仍有主動路徑。
  唯讀驗收前檢查是否有現存預約；不要操作這些按鈕。`-quotaKeeperEnabled NO` 僅為本次啟動覆寫，
  不代表持久化偏好已關閉；每次啟動前重讀 `defaults read com.vinz.codenotch quotaKeeperEnabled`，
  不沿用舊 session 的值；檢查共用 settings 是否有預約，不帶旗標可能啟動守護。開啟守護可能在 weekly 0%
  reset 時送出請求（含 Claude／Antigravity），不得把當下 weekly 非 0 當成設計保證；真實 poke 另需明確同意。
- **卡片「有值」不等於「讀成功」**：可能是 `lastGood` 快取。用 `defaults export com.vinz.codenotch -`
  讀 `lastGoodReadings` 的 `fetchedAt` 跨來源比對——只有某一家落後，就是那一家在失敗，不必猜原因。
  provider 與引擎要**分層各查一次**：provider 有 CLI 退路、引擎（曾）沒有，Claude 就這樣卡片正常而引擎
  停讀四天。引擎那層看 `state.json` 的 `snapshot.observedAt` 與 activity 最後一筆「讀取 rate limits」。
- 錯誤型別已指出責任歸屬，先看型別再查：Antigravity `invalidUsage` 代表 CLI 有跑且有回應（**不是** sandbox 或路徑問題），`binaryNotFound`／`backgroundReadFailed` 才是。
- live read 沿外層診斷規則；Antigravity 真實讀取只由 App 執行官方 CLI。更換模型、prompt、安全旗標或
  放寬重送次數需明確同意；固定值以外層規則為準。
- token、auth.json、完整帳號 ID、email、fingerprint、OAuth URL／state、私人狀態不得進 repo 或外部服務；
  規則檔／commit message 不記帳號 label，驗收僅輸出去識別的必要資料。讀系統 `~/.codex/auth.json`
  （`CodexActiveAccount`）只取 `tokens.account_id` 算指紋即丟，同檔 token 不得讀出、記錄或存檔；App 未開
  App Sandbox（`project.yml` 有註解說明原因），讀得到不代表可以讀更多。
- Rust 退役須全部驗收通過，再盤點實際 App／啟動入口，列具體清單供確認；舊 App／資料移入 `mktemp -d` 備份，不用 `rm -rf`，共用資料目錄保留。

## 8. 進度與續作入口（2026-09-16）

進度以 `git log` 為準，本節不釘 hash。已提交：引擎移植、子程序隔離、鎖回收與 heartbeat、共用
`ClaudeCooldown`、engine snapshot 直送 UI、Antigravity 5h 依方案選配；外層 Rust repo 亦已提交。
**工作區未提交**：/simplify 清理、使用中帳號改 accent 框線（已實機確認）、Claude 憑證失效時的讀取降級、
Antigravity 逐組 activity（後兩者見 §5）。最新驗證 **1262 tests、1 skipped、0 failures**，簽章／Universal
通過，已安裝 `/Applications/Codenotch.app` 並實機確認降級讀取與逐組記錄都生效。**守護已由使用者開啟**
（=1），**Antigravity 首次真實 poke 已放行**（兩組各一次最小請求、不重試），至今因兩組 weekly 仍 0%、
倒數未啟動而未觸發。

證據界線：上述由 fake backend／parser／controller、互動 motion、競爭 lock、save failure、parent＋child
timeout 測試涵蓋，**不等於真實 poke**；Antigravity 已實機確認免費方案（僅每週）可解析。Claude 鑰匙圈
`OSStatus -25293` 是常態而非偶發（見 §5 token 輪替、§7 分層診斷）。降級取樣算出 Claude 滿一個 5h ≈ 10.6% 週額度，
與 Rust 實測 11.8% 相符，可視為 burn-rate 與降級路徑的交叉驗證。

續作先核對**實際執行版本、授權、keeper／預約／cached 狀態**，再處理：
- Antigravity 首次真實 poke 已放行；事後核對兩組 `lastPoke.status` 與時間序列，不以 exit 0 論成功。
- 授權失效**不是** ad-hoc 重建造成的：實測換一份 ad-hoc 建置後 Always Allow 仍有效，Makefile 那段註解
  在這個鑰匙圈項目上不成立。別再去追 Xcode 憑證（`make install` 缺 "Mac Development" 會失敗），靠 §5 降級。
- Dock／hover 開關、多螢幕、高對比、Reduce Motion、idle CPU（VoiceOver 不列入驗收，使用者決定）；睡眠喚醒
  與真實取消／timeout 依先前決定擱置。**Rust 不可宣告可退役**，外層規則尚未搬入。
- 已決定另案（實機驗收後再做）：`QuotaBackend` 加 `cooldownDeadline`；outcome 帶回 persisted snapshot 取代手抄 allowlist（為何不能走 observedAt 捷徑見 §4）；process group 推廣到其餘四個手刻 `Process()`。
