<!-- 本檔是本專案唯一規則檔；CLAUDE.md 是指向本檔的 symlink。
     裁減／最佳化時只刪過期或重複內容，不得刪除任一工具專屬規則。 -->

# AGENTS.md — Khih（khih）

全域規則見 `~/.codex/AGENTS.md`。quota 安全不變量保存在 `docs/quota-safety-contract.md`；
該檔保留舊 Rust 專案契約，Swift 的較新決策以本檔為準。
優先順序：system／developer／使用者最新明確指令 > 本檔 > 全域規則。

## 1. 範圍與工作方式

- Khih 是 `~/projects/khih` 的獨立 Swift／SwiftUI + AppKit repo，fork 自 `vinzdg/codenotch`，已移植 Rust quota 引擎；
  `CONTRIBUTING.md` 是 upstream 檔，不改，**維持 Codenotch 原有 UI/UX 是硬需求**。
- **品牌字串分兩類，全域取代必定誤傷**：現行識別要改（bundle ID `tw.lokun.khih`、log subsystem、顯示名、
  module、檔名）；**事實記述不可改**——上游 repo `vinzdg/codenotch`、migration 來源 `com.vinz.codenotch`
  （改掉＝既有設定全失）、@Im-Midi 的 `codenotch-windows` URL、上游 icon 出處及 upstream dated 文件。
  `CONTRIBUTING.md`／`TASKS.md`／`docs/plans|specs/` 原則上整份不改；隱私修復須另取得修改／改史授權。
- fork 要清的不只名字：`SUFeedURL`／`SUPublicEDKey`（上游 feed 會**自動把這個 App 換成上游建置**）、
  `DEVELOPMENT_TEAM`、下載主機、上游簽章的 `site/`；upstream merge 後重查 `project.yml`／`Info.plist`。
- 發布原始碼或 binary 前盤點第三方授權並實際檢查 App bundle；SwiftNIO 2.102.0 的 Apache-2.0
  `LICENSE.txt`／`NOTICE.txt` 必須隨 object form 散布。保留 Vinz、Im-Midi、LobeHub 的既有著作權與 notice。
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
- **5h 自動守護獨立於週守護、預設關閉**。任何 5h request 前先 atomic 保存
  `fiveHourStarter.automaticAttemptAt`（Antigravity 各組獨立）；保存失敗不得送。只有 request 後的新鮮 endpoint
  讀值確認倒數運作才清 latch 並保存 `confirmedResetAt`；移動的 provisional reset、重啟、重新開關、CLI
  fallback 都不得解鎖。未確認時自動路徑持續觀測但不重送，手動仍可處理；manual／scheduled 送出前也要立 latch，避免自動路徑緊接重送。
- state／settings 用語意 round-trip，比較解碼值而非 byte-diff（Rust Option 的 `null` 與 Swift 省略 key 都可
  解碼，已實機確認 Rust 能讀）。百分比超出 0–100 整次拒絕不 clamp；時間戳截斷不四捨五入，秒／毫秒以 `> 1e11` 判別。
- Claude weekly 首次缺席只保存 pending，不得 poke，手動亦同；再次缺席且既有預定 reset 已過
  才可走 transaction。Swift 曾漏移這段，修改時須保留對應的首次缺席與 pending reset 回歸測試。
- 身分未確認不得送出 Codex／Claude 請求。429 冷卻內不可碰身分或 usage backend，5h 亦不得繞過；
  `Retry-After: 0` 視為無指引退回 15 分鐘，每次 HTTP request 都驗 User-Agent。子程序解析用
  `Lazily<Value>`，不可在 init 預設參數或主執行緒提前跑 `claude --version`。
- `.live` 才是週守護；`.manual` 保留所有安全閘門、不發系統通知；`.observe` 只更新 baseline／
  burn-rate，不進 poke transaction。守護關閉時的自動取樣走 `.observe`，不是偷偷改成 `.live`。
- 週守護與 5h 守護同輪時先跑 weekly，再重讀 5h 閘門；cooldown 必須在身分／backend 前阻擋。
  5h `.automatic` 遇帳號使用中、首次 baseline、Claude 無 endpoint 或 Antigravity 缺 5h 時只略過，不送請求。
- 檢查、5h、登入與預約到點觸發共用 controller 忙碌限制；transaction 保留每帳號 `check.lock`。
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
  快取鍵並在 `UsageStore.tick()` 重算，否則 ring 不會換。該組以 **accent 色框線**標示（已實機確認，`LimitWindow.isActiveAccount` → `TooltipWindowGroup`）而非文字；色彩非唯一訊號，`accessibilityLabel` 仍要唸出「In use」。
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
- 左鍵由 `NotchPanel.sendEvent` 統一路由；SwiftUI／輔助使用共用動作，避免一次按下執行兩次。保留設定鈕、
  釘住與 Option 拖曳。`detailsOnClick` 預設 true（懸停不開，關閉才恢復 hover）；`detailsShowRemaining` 預設 false，只切詳細頁 bar＋百分比，不改 ring、警告色或引擎證據。兩者皆保存。
- 設定視窗可暫時升為 `.regular`，關閉後必須 `.accessory`，不能因偏好 `.dock` 留在 Dock；
  `SettingsPanel.miniaturize` 走 `performClose`，不留縮圖且保留登入清理閘門，App 與 ring 繼續執行。
  「已連線」依 `ProviderFamily` 分 Section，分組只做在呈現層，底層仍是扁平陣列（拖曳排序直接操作它），跨組拖曳回傳 false。
- 設定頁**沒有**「Install updates automatically」與「Check now」（Sparkle 已移除），只剩版本文字＋「此建置不會自動更新」。這是已決策改動、不是 UI 退化，不要依 §1「維持原有 UI/UX」改回去。
- `SettingsView.quota` 是普通 `var` 而非 `@ObservedObject`，`.onChange(of: quota.…)` **不會觸發**；
  要即時更新就從已觀察該物件的子 view 往上回呼（`AddCodexAccountSection.onAdded`）。
  列表是 `@State` 快照；帳號摘要不得為顯示方案名稱載入秘密憑證，也不綁輪詢反覆重建。
- 讀取失敗的帳號不可從明細消失；保留既有讀值並揭示過期／錯誤，不把 unknown 填成 0%。
- 過期 reset 只有最新讀值可顯示「重置中」；stale 且正在讀取顯示 `Checking…`，失敗顯示
  `The reading is out of date.`。manual check 以 `QuotaController.onQuotaSnapshot` 將引擎已讀 snapshot
  發布給 `UsageStore`，不可完成後再 `store.refresh` 重讀同一來源；轉換須保留三家 window ID／headline。
- **同一份顯示轉換只能有一處**：Antigravity 視窗走 `AntigravityCLIProvider.windows(from:)`，headline 走各家
  `*Usage.headlineID(in:)`；provider 輪詢與引擎 `publishQuotaSnapshot` 呼叫同一份，就地重寫會讓同一張卡片
  因上次由誰更新而換 headline。視窗 id `"<limitId>:<five-hour|weekly>"` 被 `withBurnReadings` 字面比對綁死；`AntigravityGroup.window(in:weekly:)` 是**引擎閘門**，不可當 UI 建構。
- `QuotaController` 兩處手抄的「哪些 outcome 帶新讀值」白名單**不可用「`observedAt` 是否前進」取代**：
  引擎側等價，破功的是呼叫端——session 首次呼叫沒有基準，會把磁碟舊 snapshot 當新讀值發布成 `.ok`，且每
  螢幕各有 controller，`UsageStore` 守衛是 `>=` 會放行重發。唯一解是 §8 已排的另案，不是清理範圍。
- 新登入經 fingerprint 去重後呼叫 `onAccountsChanged`：重新探索 profiles，`UsageStore.addProviders` 只
  增補新 ID，接上新 monitor／5h 清單，不重建 store、不要求重啟。新增 Codex 走設定視窗原生 sheet（命名→
  登入→完成，代碼可選取）：失敗保留名稱重試，重複登入明說未新增，取消／逾時須等程序與暫存帳號清理才結束。
- 點擊手感與 backend 等待分開：縮入 0.93 倍、380ms 後釋放，保留有限旋轉／spring；等待短弧用獨立
  `TimelineView` 持續轉、完成即停。動畫範圍各自限定，Reduce Motion 靜態提示；共享回饋沿用 `UsageStore.refreshing`，frame 未變不要 `setFrame`。
- 文案走 `L10n.t` 的英文 literal key，繁中 locale 是 **`zh-Hant-TW`**（不是 `zh-Hant`）；插值 `%@`，字面
  百分號要 `%%`。`Localizable.xcstrings` key 為插入序，新 key 只 append 且先查是否已存在（`Checking…` 早有
  譯文），不重排整檔。**改 key 等於換 key**：要同批帶走譯文，否則舊譯文孤立、英文悄悄 fallback。
  譯文的格式參數序列必須與 key **逐字逐序相同**，不可改寫成 `%1$@`／`%2$@`（`testTaiwanTranslationsPreserveFormatArguments` 逐一比對，會擋下來）。改 `.xcstrings` 只能純文字 append；`json.load`／`json.dump` round-trip 會改掉整檔 separator 樣式，diff 變成三千多行。
- 改名（僅受管理帳號）存 `accounts.json` 的 `displayName`，**不是 `label`**：Claude／Antigravity 的 label 是 email，升格成 ring 名稱等於把地址放上瀏海。nil＝沿用 provider 自己的名字；唯一套用點是 `UsageStore.publish`／`providerSummaries`（provider 的名字是 launch 時建好的，改名不會自己傳過去）。凡顯示名稱都走這裡，不可用 `displayLabel`（同樣漏 email）。
- **只有會送請求的控制項才綁 `quota.isBusy`**（引擎側不變：到點觸發仍受 §3 忙碌限制，`takeDue` 忙碌時全部保留）：預約、改名只寫一個小檔，掛上 busy 閘門後一輪 check（健康時約 10 秒，Codex 逾時可達 65 秒，點 ring 也會觸發）就讓按鈕變灰，而 disabled 的 SwiftUI Button 按下去毫無回饋——使用者看到的是「這功能壞了」，且磁碟上不會留下任何痕跡可查。
- **每列自己的錯誤訊息不可放共用 ObservableObject**：`QuotaSchedule` 曾用單一 `@Published error`，一次拒絕就把橘字同時印在四張卡片下，還會被別人成功的預約清掉。改成 `set()` 回傳訊息、各 view 自己 `@State` 持有。
- 預約 UI：每張卡片一行狀態＋popover 選時間，底部只做「套用到全部」與已預約清單。DatePicker 不設 `in: Date()...`（下限每次重繪前移，會打斷輸入），改成按下時檢查、過去時間由 `set()` 回傳訊息。
- tooltip 新增資訊時同步調整 `NotchLayout.cardHeight` 與所有 hover／panel 計算，用匿名三帳號 fixture 驗證完整六個 window。
- **重連 2 秒是完成上限，越快越好**：恢復連線立即讀取，各來源完成即發布，不等慢來源；全部完成立即判定 `recoveryPassed` 並取消 deadline，不固定等滿 2 秒。逾時仍可更新讀值，但不得把該次驗收改判成功。
  所有啟用來源均須取得新讀值；「開始檢查」、spinner、舊快取、fake 測試通過皆不能替代實機證據。Codex quota／profile enrichment 可平行；不得硬砍安全 timeout，或放寬 Claude CLI fallback、Antigravity 序列化 client、poke verification。
  回歸測試須在明顯早於 2 秒時檢查快速完成及判定，另驗快速來源不被慢來源擋住；只等到 2 秒後斷言會漏掉固定等待的退化。這不改 §3 `countdownWindowActive()` 的安全門檻。
- 重連延遲先查 `UsageStore.networkChanged`／`NWPathMonitor`、一般輪詢間隔、provider 快取與未結束讀取；只縮短 timer 不會清除快取、結束卡住的讀取或補上重連觸發。
  重連走唯讀 `fetchSnapshotAfterReconnect()`；Claude 清 CLI 快取，略過一般輪詢等待但保留 429 冷卻。同來源先等舊讀取退出，等待也計入 2 秒，不平行開第二個 CLI。
  `NWPath` 可用只是觸發，不代表服務可達；目前紀錄以收到 path callback 起算，不能宣稱已量到系統連線恢復至 callback 的延遲。provider 更新也不等於引擎完成檢查。

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
  則略過。狀態存在 `antigravityGroups.{gemini,claude_gpt}`，UI／通知逐組回報，不以一組成功掩蓋另一組失敗。
  每組每次檢查都寫 activity（讀值一行、結論一行 `QuotaEngine.activityLine(for:)`，措辭與 provider 路徑逐字相同），寫在 `checkAntigravity` 呼叫端而非各分支內，否則新增分支會靜默；`.observe` 只寫讀值。
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
- 單次預約**每帳號各一筆**：`settings.json` v1／`fiveHourStartAtByAccount`，key 是 account id（`claude`／`gemini` 是顯示 id，不寫回儲存狀態）。沿用舊 key `fiveHourStartAt` 會讓 Rust 的 `Option<i64>` 整份解不動；沒有預約就不寫這個 key。台灣時間 UI、Int64 引擎，每秒只看記憶體。
- 到點忙碌**全部**保留不清，**超過** 3600 秒才取消（恰好一小時仍可執行），逾期只寫自己那一筆 activity；不在 targets（停用／已移除）者不觸發但照樣逾期清掉。一次 atomic 清空所有到期帳號再啟動，儲存失敗全部不送，只啟動當次到期的那幾個。App 未執行／睡眠不執行，不建 LaunchAgent。拒絕亦寫「預約觸發」activity。
- 5h 守護沿用 controller 每秒 tick，但 tick 只比對記憶體 deadline；啟用／啟動／喚醒立即檢查，正常失敗每
  300 秒再觀測，確認倒數後依 reset 接續。忙碌保留、關閉以 generation 撤銷未開始工作；已送出的 request 完成驗證與存檔。不補送 App 關閉／睡眠期間錯過的輪次，也不另發系統通知。

## 6. Build、測試與診斷

```sh
make gen       # 新增 Swift 檔必須；build／test 已包含
make test-ci   # 本機 make test 會選到 Apple Development 簽章而失敗
make build DEV_SIGN='CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'
make build-ci  # 唯一能產出「可實際啟動」的 ad-hoc Release App
```

- `make build` 出來的是 **Debug**，程式碼在 `Khih.debug.dylib` 而非主執行檔——`nm` 驗新符號時挑錯
  檔案會得到「新程式碼不在裡面」的假結論。`make archive` 需要 Developer ID；要能雙擊執行的用
  `make build-ci`，它多帶 `disable-library-validation`，否則 ad-hoc 簽章會讓 dyld 啟動時擋下內嵌的
  Swift runtime library（`codesign --verify` 照樣通過，只有真的啟動才看得出來）。
- **只保留 `/Applications/Khih.app` 作為安裝版**（使用者已決定）：依 build log 定位產物，安裝驗證後移除多餘 Debug／Release App 副本及其 LaunchServices 登錄；以檔案掃描＋Spotlight 核對，保留原始碼、驗證紀錄與共用資料。
  啟動一律用完整路徑；`ls -dt` 會挑錯 DerivedData。Release 最佳化可能消除型別名，缺 symbol 不等於沒編入，須再核對實作字串／產物 hash 與繁中 `Localizable.strings`。
- `.xcodeproj` 由 `project.yml` 生成、不進 git；首次 build 可能需下載 SwiftNIO。備份移出 Sources 掃描範圍後再 `make gen`，gen／build 不與檔案移動並行。
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
- **螢幕鎖定是一個原因、三種症狀**，先查 `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` 再懷疑程式碼：①EdgeArrival／EdgeCrossfade 全數失敗（動畫沒跑，斷言停在初始邊）②它們的 `TimelineView` 迴圈耗盡 dispatch thread pool，**讓後面的測試整個卡住**，看起來像「我新加的測試 hang 住」——`sample <pid>` 會印 `Dispatch Thread Soft Limit: 64 reached`，把該 class 單獨 `-only-testing:` 跑通即可排除 ③`screencapture -l<ID>`／`-R` 回 `could not create image`（全螢幕擷取仍可）。要乾淨數字就 `-skip-testing:KhihTests/EdgeCrossfadeTests -skip-testing:KhihTests/EdgeArrivalTests`，並在報告寫明扣掉幾項。
- 飄測試仍須用乾淨 HEAD 的獨立 worktree／DerivedData 比對（worktree 的 scheme 名可能還是舊的），用完 `git worktree remove`；HEAD 通過不能宣稱「已證明是環境」，不放寬斷言求過關。
- 渲染環境用 `TEST_RUNNER_GROUPED_RENDER_DIR`／`TEST_RUNNER_RING_RENDER_DIR` 傳入 test host，單設外層同名
  變數不保證傳入；原生文字用 NSHostingView＋AppKit bitmap 與明確背景，ImageRenderer 的禁止符號／透明黑底
  圖不能當通過。互動驗收含四邊緣／兩縮放、三同名匿名帳號六視窗、組間空白、連點／跨螢幕單飛、動畫超過首圈仍動與不殘留。
- 證據一律**重跑取得**，本檔不引用 `/tmp` 路徑（會被清掉，過時 log 比沒有更糟）。AX 失效／screenshot
  unavailable 不算介面驗收成功；程式測試、渲染、實機驗收分開回報。AX 失效改走 `CGWindowListCopyWindowInfo` 找 window ID 再 `screencapture -l<ID>`；拍不到就交使用者看。
- **zsh 的 `log` 是內建指令**：一律寫 `/usr/bin/log`，否則靜默回空，會得到「App 沒輸出日誌」的假結論；
  test host 與 App 共用 subsystem，查執行中的 App 要加 `--predicate 'processIdentifier == <pid>'`。
  **驗證指令不可接 `head`／`tail`**：SIGPIPE 會把 `make test-ci` 一起殺掉並留下損毀的 xcresult（看起來像
  測試失敗），截斷也會吃掉測試總數；一律 `> 檔案 2>&1` 再 grep 全文。BSD sed 不支援 `\b`，改用 Python。
  `pgrep`／`git rm`／`grep -c`（計數為 0 時）找不到目標會回非 0，接 `&&` 會靜默跳過後面的 heredoc，看起來像已執行過。

## 7. 資料與實機操作禁區

- 共用資料目錄：`~/Library/Application Support/codex-quota-keeper/`；保留既有 baseline／fingerprint。
  診斷或啟動前先 `pgrep -x Khih`、`pgrep -x codex-quota-keeper`，兩 App 不得同時執行；不得擅自
  關閉既有 App，已取得的明確重啟授權可沿用，不重複問同一動作。
- **關閉一種守護不等於完全不送請求**：另個守護、手動 5h／立即檢查與單次預約仍是主動路徑。
  啟動前重讀兩個 defaults（key 不存在＝false）與 `fiveHourStartAtByAccount`；唯讀驗收用完整路徑加
  `-quotaKeeperEnabled NO -fiveHourKeeperEnabled NO`，只覆寫該次啟動、不改持久化偏好。不要操作 request
  控制項；cached weekly 非 0 不是安全保證，真實 poke 仍需明確同意。
- **UI 說「按了沒反應」時，先看它該寫的檔有沒有被寫過**（`ls -la` 比 mtime，不必解析內容）：`settings.json` 內容只有 `{"version":1}` 且 mtime 停在兩週前，就證明 `set()` 從來沒被呼叫過，一步把範圍從「儲存壞了／引擎壞了」收斂到「按鈕根本按不下去」。接著才用 `AskUserQuestion` 給 2–4 個具體症狀選項，別靠猜。
- **卡片「有值」不等於「讀成功」**：可能是 `lastGood` 快取。用 `defaults export tw.lokun.khih -`
  讀 `lastGoodReadings` 的 `fetchedAt` 跨來源比對——只有某一家落後，就是那一家在失敗，不必猜原因。
  provider 與引擎要**分層各查一次**：provider 有 CLI 退路、引擎（曾）沒有，Claude 就這樣卡片正常而引擎
  停讀四天。引擎那層看 `state.json` 的 `snapshot.observedAt` 與 activity 最後一筆「讀取 rate limits」。
- 錯誤型別已指出責任歸屬，先看型別再查：Antigravity `invalidUsage` 代表 CLI 有跑且有回應（**不是** sandbox 或路徑問題），`binaryNotFound`／`backgroundReadFailed` 才是。`backgroundReadFailed` 在連續操作下常是暫時的（讀值行有數字、只有結論行失敗），下一輪會自行恢復，別當 sandbox 壞掉去追。
- live read 只由 App 執行；任一 provider cached usage 0%、unknown 或主要 weekly 缺席時，先取得使用者確認。Antigravity 只由 App 執行官方 CLI。更換模型、prompt、安全旗標或
  放寬重送次數需明確同意；固定值見 `docs/quota-safety-contract.md`。
- token、auth.json、完整帳號 ID、email、fingerprint、OAuth URL／state、私人狀態不得進 repo 或外部服務；規則檔／commit message 不記帳號 label，驗收只輸出去識別資料。`CodexActiveAccount` 只從 `~/.codex/auth.json` 取 `tokens.account_id` 算指紋即丟；App 未 sandbox，讀得到不代表可讀更多。
- 公開前掃**遠端預設 branch 的完整歷史**而非只掃 HEAD／worktree：用 redacted secret scanner，再人工複核 author email、歷史檔名、dated docs、binary／archive、dependency notices；`SUPublicEDKey`／fixture token 確認用途後才算誤報。有帳號 ID／email 或授權缺口就不得宣稱乾淨或執行有「審核全過」前提的 README／發布；改史或刪 upstream 史料須另授權。

## 8. 進度與續作入口（2026-09-22）

提交狀態以 `git log`＋整個 repo 的 `git status --short` 為準，不釘 hash／PID。先核對實際執行版本、既有授權、keeper 啟動參數／持久化偏好、預約與 cached 狀態；以下區分本輪與先前紀錄，不能當成下次現況。

- **未 commit 工作區**：Khih 改名／簽章／Sparkle 與 `site/` 移除、每帳號預約、改名、重連、5h 自動守護與規則；範圍重查 `git status --short`。共用資料目錄仍是 `~/Library/Application Support/codex-quota-keeper/`，不可因舊名刪除。
- **5h 自動守護完成**：獨立開關、deadline／喚醒、跨重啟 latch、weekly／manual／schedule 競爭、Claude endpoint 與 Antigravity 分組均有 fake 回歸；全套 **1297 tests／1 skipped／0 failures**。未做真實自動 poke、睡眠喚醒或到期接續驗收。
- **已重裝單一 App**：`/Applications/Khih.app` 1.7.0／9 的 codesign、manifest、繁中與 SwiftNIO notice、單一 instance 通過，多餘 App 已移除。現以兩 keeper `NO` 啟動；持久化 weekly＝1、5h key 不存在（false）、無預約，下次一般啟動恢復 weekly。
- **公開歷史待使用者改寫**：`main` 136 commits、fork 自有 12；Gitleaks 5 筆皆為公開金鑰／fixture 誤報，DMG 另掃 0。工作區已匿名化 `TASKS.md`、repo email 改 noreply，隔離 `filter-repo` 演練保留全部 commits 並清掉目標；正式 force-push 尚未執行，upstream DMG／appcast 仍只在 public tip。
- **授權補件已修**：MIT／Vinz、Windows Im-Midi／LobeHub notices 保留；SwiftNIO 2.102.0 Apache `LICENSE.txt`／`NOTICE.txt` 已加入、Release bundle hash 相符。README 已加入 upstream UI／UX 致謝；正式改史前仍不可宣稱公開歷史完全乾淨。
- **仍未驗收**：實際重連 2 秒、Dock／hover、多螢幕、高對比、Reduce Motion、idle CPU、睡眠喚醒、真實取消／timeout；fake 或啟動讀取不能代替實機證據，既有 poke 授權不擴張。
- **另案**：`QuotaBackend.cooldownDeadline`、persisted snapshot outcome、其餘 `Process()` 的 process group；清 Git history 須另行規劃 force-push／fork cache／協作者重抓與回復。
