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
- git 由使用者處理：不得代為 commit 或改 history。不要將工作區未提交的功能寫成已 commit。
- 回報改動規模或提議 commit 前先 `git status --short` 看**整個 repo**，不要只看自己編輯的檔案就報數字；
  審查工具只看 tracked diff，未追蹤新檔會被誤報成「型別未定義、編不過」，先查 `git status` 再信。
- 規則檔只收反覆出現、可歸因、窄改動可避免的問題；一次性的編譯拼字錯誤不增列制度。
- 改規則前先 `ls -la AGENTS.md CLAUDE.md`；維持 `CLAUDE.md -> AGENTS.md`。
  大改未追蹤／不乾淨檔案前先備份；本檔維持 250 行內。

## 2. 架構與承重檔案

`UsageProvider` 是純唯讀觀測者；會送請求的 quota 引擎獨立一層，在 `AppDelegate` 接線。
不得把 poke 偷塞進 provider 的重新整理，也不得用 UI 百分比替代引擎證據。
| 檔案（未註明者在 `Sources/Quota/`） | 職責 |
|---|---|
| `QuotaDomain.swift` / `QuotaState.swift` | 純安全邏輯、Int64 window、state v2、burn-rate／deadline |
| `QuotaStorage.swift` | accounts／settings、atomic write、check.lock recovery／heartbeat、activity |
| `QuotaEngine.swift` | check／5h／共用 verifyPoke |
| `AntigravityEngine.swift` | 兩群組 transaction，各組獨立結果與狀態 |
| `QuotaController.swift` / `QuotaSchedule.swift` | MainActor 門面、忙碌限制、登入、通知、排程與取樣 |
| `QuotaProcess.swift` / `QuotaCancellation.swift` / `BackgroundCLI.swift` | 子程序、pipe、取消與禁止背景開啟瀏覽器 |
| `CodexAppServer.swift` | NDJSON JSON-RPC、device auth、fingerprint |
| `ClaudeUsage.swift` / `ClaudeBackend.swift` | Claude parser、身分、usage／poke、429 |
| `AntigravityUsage.swift` / `AntigravityBackend.swift` / provider | agy parser、序列化 client；來源 ID gemini |
| `QuotaBurnReading.swift` / `Model/UsageStore.swift` | 引擎樣本、burn reading 與顯示發布；不影響 poke |
| `FiveHourScheduleSection.swift` / `AddAccountSection.swift` / controls | 預約、登入、5h／檢查 UI 文案 |
| `Model/ProviderOrder.swift` / `Providers/CodexActiveAccount.swift` | 多來源合併、目前帳號、window ID／headline |
| `Providers/KeychainAccess.swift` / `Providers/ClaudeCredentials.swift` | 序列化 Security 存取、靜默讀取／明確授權、共用快取 |
| `Features/ProviderRing.swift` / `Features/QuotaDetailDisplay.swift` | 獨立點擊／等待動畫；詳細頁已用／剩餘呈現 |
Upstream 合併接點：`App/AppDelegate.swift`、`Settings/SettingsView.swift`、`Providers/CodexProfile.swift`、`Notch/NotchWindowController.swift`、`App/StatusItemController.swift`。

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
- stale lock 回收須持有 `check.lock.recovery` 的 `flock`；釋放前比對 descriptor／路徑 inode，
  不可用 stat→unlink→create 的 TOCTOU 流程。帳號清理須先成功保存 `accounts.json` 才刪目錄並向 UI 回錯。

## 4. 已決策的 UI／多帳號契約

- **Antigravity 一個 ring；Codex 多帳號合成一個 ring，tooltip 分組明細**；帳號／群組數不等於 ring 數。
- 帳號仍各自擁有 provider、設定列、開關、憑證、baseline、lock 與 quota state；只合併顯示。
- 來源 ID 固定：Codex `codex-<id>`、Claude `claude`、Antigravity `gemini`，不可改為 `antigravity`。
  Codex 合併 cell 為 `codex:accounts`，不把這個顯示 ID 寫回帳號或當成 backend ID。
- 合併使用 `ProviderOrder.cells`；多來源用 `sourceProviderIDs`／`refreshProviderIDs`。
  重新整理、spinner、session activity 要涵蓋所有來源；各 window ID 加來源前綴，不能撞名。
- 合併函式須冪等：store 與 notch 都可能呼叫，不得把已合併 cell 再合併或重複展開。
- 主數字／ring 一律顯示**5 小時剩餘**，不加總／平均不同帳號的百分比。
  「剩餘最少的 window」只在找不到 5h window 時當退路，不得拿週額度搶走 headline。
  Antigravity 取 `antigravity:gemini:five-hour`，缺席時退回 weekly（免費方案現況）；Codex 取
  **目前登入帳號**的 5h。
- 目前登入的 Codex 帳號＝`~/.codex`（或 `CODEX_HOME`）與各帳號 `auth.json` 指紋相符者，用既有
  `CodexFingerprint.of(codexHome:)`，不另寫 hash；比對不到退回第一個有 5h 的帳號。以 `auth.json` mtime
  當快取鍵並在 `UsageStore.tick()` 重算，否則沒有新讀值時 ring 不會換。該組標題加「使用中」標記。
- 有 managed 帳號時，卡片／設定頁不列 `~/.codex` 預設 profile，避免重複；無 managed 帳號才保留。
- Claude 的存活行程不代表工作中，卡片不顯示即時工作階段；統一在 `NotchViewModel.activity(for:)` 過濾，
  不在各 sessionCount 計算點分散判斷。額度列名稱與其他家對齊（`5h limit`／`Weekly limit`），但視窗 id
  仍是 `session`／`weekly_all`（`headlineID` 靠它）；`ClaudeUsageCLI` 解析的 `Current session:` 是
  Claude CLI 的輸出格式，不是我們的文案，不可改。
- 三家受管理 ring 左鍵＝展開詳細頁並 `.manual` 立即檢查；Codex 按顯示順序逐帳號 await，
  Antigravity 仍逐群組保存結果。`QuotaController.checkBatch` 整批維持 busy，不能只鎖單帳號。
  每個螢幕各有 controller；連點／跨螢幕需看引擎 `isBusy`，忙碌不另發重新讀取。
- **Codex 群組左鍵＝只對該帳號 `startFiveHour`**；這取代舊「左鍵不可啟動 5h」限制。
  右鍵 5h 保留；非 Codex 卡片沿用立即檢查，卡片外空白仍釘住；群組間空白不送請求。
  `TooltipWindowGroup`／`groupID`／`sourceProviderID` 為識別依據，不能用名稱或陣列位置。
  命中區取自繪圖實際 frame；標題＋額度框共用點擊區，結果顯示於該組。
- 左鍵由 `NotchPanel.sendEvent` 統一路由；SwiftUI／輔助使用共用動作，避免一次按下執行兩次。保留設定
  按鈕、釘住與 Option 拖曳。`detailsOnClick` 預設 true（懸停不開，關閉該選項才恢復 hover）；
  `detailsShowRemaining` 預設 false，只切詳細頁 bar＋百分比，不改 ring、警告色或引擎證據。兩選項皆保存。
- 設定視窗可暫時升為 `.regular`；關閉後必須 `.accessory`，不能因偏好 `.dock` 留在 Dock。
  `SettingsPanel.miniaturize` 走 `performClose`，不留縮圖且保留登入清理閘門；App 與 ring 繼續執行。
- 設定頁「已連線」依 `ProviderFamily` 分 Section；分組只做在呈現層，底層順序仍是扁平陣列（拖曳排序直接操作它），跨組拖曳回傳 false。
- `SettingsView.quota` 是普通 `var` 而非 `@ObservedObject`，`.onChange(of: quota.…)` **不會觸發**；
  要即時更新就從已觀察該物件的子 view 往上回呼（`AddCodexAccountSection.onAdded`）。
  列表是 `@State` 快照；帳號摘要不得為顯示方案名稱載入秘密憑證，也不綁輪詢反覆重建。
- 讀取失敗的帳號不可從明細消失；保留既有讀值並揭示過期／錯誤，不把 unknown 填成 0%。
- 過期 reset 只有最新讀值可顯示「重置中」；stale 且正在讀取顯示 `Checking…`，失敗顯示
  `The reading is out of date.`。manual check 以 `QuotaController.onQuotaSnapshot` 將引擎已讀 snapshot
  發布給 `UsageStore`，不可完成後再 `store.refresh` 重讀同一來源；轉換須保留三家 window ID／headline。
- 速度目標是正常路徑約 2 秒與立即誠實回饋，不是硬砍安全 timeout。Codex quota／profile enrichment
  可平行；Claude CLI fallback、Antigravity 共用序列化 client、poke verification 不為速度放寬。
- Ollama 多模型仍沿用 `notchSnapshots` + `sourceProviderID`；不要為這次合併重寫其結構。
- 新登入成功經 fingerprint 去重後，呼叫 `onAccountsChanged`：重新探索 profiles，
  `UsageStore.addProviders` 只增補新 ID，接上新 monitor／5h 清單；不重建 store、不要求重啟。
- 新增 Codex 用設定視窗的原生 sheet：命名→瀏覽器登入→完成，代碼可選取／複製。失敗保留名稱供重試；
  重複登入明說未新增。取消／Escape／關閉／逾時都須等程序與暫存帳號清理後才結束或接受下一次登入。
- 點擊手感與 backend 等待分開：縮入 0.93 倍、380ms 後釋放，保留原本有限旋轉／spring；等待短弧用獨立
  `TimelineView` 持續轉，完成移除即停止，不能一圈後停住或永遠縮小。額度變化、旋轉、縮放分別限定動畫
  範圍；Reduce Motion 靜態提示。共享回饋沿用 `UsageStore.refreshing`；frame 未變不要 `setFrame`。
- 文案走 `L10n.t` 的英文 literal key，繁中 locale 是 **`zh-Hant-TW`**（不要用 `zh-Hant`）；插值字串為
  `%@`，字面百分號要 `%%`，例如 `Full 5h ≈ %@%% weekly`。`Localizable.xcstrings` key 為插入序，新 key
  只 append，append 前先查是否已存在（例：`Checking…` 早有「正在檢查…」），沿用既有翻譯、不重排整檔。
  驗證既有 key 內容與順序未變；新增插值文案加繁中斷言並目視渲染，避免英文悄悄 fallback。
- tooltip 新增資訊時同步調整 `NotchLayout.cardHeight` 與所有 hover／panel 計算，
  使用匿名三帳號 fixture 驗證完整六個 window，不只確認 image 非空。

## 5. Antigravity、子程序與排程

- 額度唯一來源：官方 `agy -p /usage --output-format json` 成功 envelope 的 TSV。只接受 Gemini 與
  Claude／GPT 兩組；weekly 必要，缺 weekly／重複／非法百分比／時間整次拒絕。**5h 視方案而定**，缺時
  primary 留空不得補 0%、路徑不得移除（2026-09-14 實測無訂閱時只有 weekly，續訂後會回來）。
- CLI 依環境變數 `CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN`、`~/.local/bin/agy`、PATH 延後解析。
  登入由官方 CLI 管理，不恢復 token／OMP SQLite／bridge 讀取路徑。
- **`-p`／stdin 非終端機不保證不會登入開網頁**。Antigravity read／poke 必須經 `BackgroundCLI`：
  sandbox 限制 open、osascript、.app 啟動、Apple Events、LaunchServices lsd，另設 `BROWSER=/usr/bin/false`。
  限制失敗不得退回直接執行；CLI stderr 可能含完整 OAuth URL，不可原樣寫 log／activity。
  登入只由使用者在官方 CLI 完成；fake launcher 阻擋通過不代表真實登入已恢復。
- Claude provider／引擎共用 `ClaudeKeychain.shared`；背景與 ring 禁止互動授權，只有設定頁
  明確按「允許存取」才允許該次操作。`KeychainAccess` 序列化 process-wide Security 旗標並恢復原值，
  其他 Keychain caller 也須經共用閘門；不可並行改全域旗標或用第二份 token cache 抵消輪替偵測。
- Claude 拒絕／過期保留原因與最後讀值；不可 `try?` 壓成 signed-out 或回退舊憑證檔。
  過期 token 不送 usage；401／403 清共用快取，不新增立即重試、不自行 refresh OAuth。
  錯誤走 `LocalizedError`＋L10n，分開存取拒絕／過期／登入拒絕／HTTP；不能只報 NSError 數字。
  官方登入過期仍需使用者更新，不承諾 Always Allow 永久有效或修文案就恢復登入。
- 自動讀取間隔 300 秒；CLI timeout 130 秒、provider deadline 140 秒。
  同來源僅一個程序；`AntigravityClient` 在觀測者與引擎間共享序列化，verification 必須重新讀取。
- Gemini → Claude／GPT 順序固定；每組只送一次核准的最小請求、不重試。
  單組失敗仍處理下一組；5h 已啟動則略過。狀態存在 `antigravityGroups.{gemini,claude_gpt}`，
  UI／通知逐組回報；不得以一組成功掩蓋另一組失敗。
- `QuotaProcess` 用 nonblocking read 公平排乾 stdout／stderr；不要順序呼叫 blocking
  `availableData`，安靜程序或單邊滿 pipe 都會讓 timeout 失效。
  以 `posix_spawn` 在 exec 前建立 process group；timeout／取消對整群 TERM，grace 後 KILL 並 wait，
  `waitpid` 要處理 EINTR；結束 App 時傳遞 cancellation，測試須證明 parent／child 都退出。
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

- `make build` 出來的是 **Debug**，程式碼在 `Codenotch.debug.dylib` 而不是主執行檔——用 `nm` 驗新符號
  時挑錯檔案會得到「新程式碼不在裡面」的假結論。`make archive` 需要 Developer ID。要一份能雙擊執行的
  就用 `make build-ci`：它多帶 `disable-library-validation` entitlement，否則 ad-hoc 簽章會讓 dyld 在
  啟動時擋下 Sparkle（`codesign --verify` 照樣通過，只有真的啟動才看得出來）。
- 本機同時存在多份同 bundle ID 的 `Codenotch.app`。**啟動一律用完整路徑**，不要靠 App 名稱；
  `ls -dt` 會挑錯 DerivedData 目錄，以 build log 裡印出的實際輸出路徑為準。
- 建置內容看正確 binary 的 `nm` 與繁中 `Localizable.strings`；Release 最佳化可能消除型別名，
  缺 symbol 不等於沒編入，應再核對可辨識的實作字串／產物 hash，並與 build log 交叉確認。
- `.xcodeproj` 由 `project.yml` 生成、不進 git；首次 build 可能需下載 Sparkle／SwiftNIO。
  備份移出 Sources 掃描範圍後再 `make gen`；gen／build 不與檔案移動並行，避免引用失效備份。
- `build/` 被 gitignore；`make clean` 刪整個 build，`make build-ci` 先刪 `build/ci`（**會刪掉正在執行的
  App bundle，重建前先關閉**）。產物不可宣稱已安裝；長期保留須複製到 `/Applications` 並先取得同意。
- XCTest 只用固定時間、匿名 JSON、fake executable／backend／HTTP listener、暫存資料與隔離 defaults；
  不得讓測試碰真實 Keychain、登入或 quota。App 的 XCTest launch guard 必須保留。
- fixture 必須帶上被測邏輯真正讀的欄位。`LimitWindow` 少了 `duration`，依 duration 選 headline
  的規則會**靜默走退路**——測試照樣綠燈，卻什麼都沒驗到。
- 移除功能前 `rg` 所有 source／test 參照；只移除該功能斷言，保留 parser 等仍有效的測試。
- EdgeArrival／EdgeCrossfade 曾間歇失敗：在乾淨 HEAD 的獨立 worktree／DerivedData 跑同組比對，用完以
  `git worktree remove` 收掉。HEAD 通過不能宣稱「已證明是環境」；不放寬斷言求過關。
- 渲染環境用 `TEST_RUNNER_GROUPED_RENDER_DIR`／`TEST_RUNNER_RING_RENDER_DIR` 傳入 test host，單設外層
  同名變數不保證傳入。原生文字用 NSHostingView＋AppKit bitmap 與明確背景；ImageRenderer 的禁止符號／
  透明黑底圖不能當通過。
- 互動驗收至少含四邊緣／兩縮放、三個同名匿名帳號六視窗、組間空白、連點／跨螢幕單飛；
  動畫要驗超過首圈後仍動、讀值中途更新與完成不殘留，不能只截剛開始的一張圖。
- 證據一律**重跑取得**，本檔不要引用 `/tmp` 路徑：會被清掉，引用過時 log 比沒有更糟。
- AX 失效／screenshot unavailable 不能當成介面驗收成功；程式測試、渲染、實機驗收分開回報。AX 一路失效
  改走 `CGWindowListCopyWindowInfo` 找 window ID 再 `screencapture -l<ID>`；拍不到就交使用者看。
- **zsh 的 `log` 是內建指令**：一律寫 `/usr/bin/log`，否則靜默回空，會得到「App 沒輸出日誌」的假結論。
  test host 與 App 共用 subsystem，查執行中的 App 要加 `--predicate 'processIdentifier == <pid>'`。
- **驗證指令不可接 `head`／`tail`**：`head` 提早結束觸發 SIGPIPE，會把 `make test-ci` 一起殺掉並留下
  損毀的 xcresult（看起來像測試失敗）；截斷也會吃掉測試總數。一律 `> 檔案 2>&1` 再 grep 全文。
- BSD sed 不支援 `\b`；word-boundary 替換用 Python `re.sub`。

## 7. 資料與實機操作禁區

- 共用資料目錄：`~/Library/Application Support/codex-quota-keeper/`；保留既有 baseline／fingerprint。
- 診斷或啟動前先 `pgrep -x Codenotch`、`pgrep -x codex-quota-keeper`；兩 App 不得同時執行。
  不得擅自關閉既有 App；已取得的明確重啟授權可沿用，不重複問同一動作。
- **關閉週守護不等於完全不會送請求**：手動 5h／立即檢查與已存單次預約仍有主動路徑。
  唯讀驗收前檢查是否有現存預約；不要操作這些按鈕。`-quotaKeeperEnabled NO` 僅為本次啟動覆寫，
  不代表持久化偏好已關閉；每次啟動前重讀 `defaults read com.vinz.codenotch quotaKeeperEnabled`，
  不沿用舊 session 的值。檢查共用 settings 是否有預約，不帶旗標可能啟動守護。
- 開啟守護可能在 weekly 0% reset 時送出請求，包含 Claude／Antigravity；
  不得把當下 weekly 非 0 當成設計保證。真實 poke 另需明確同意，首次 Claude／Antigravity 尤其如此。
- **卡片「有值」不等於「讀成功」**：可能是 `lastGood` 快取。用 `defaults export com.vinz.codenotch -`
  讀 `lastGoodReadings` 的 `fetchedAt` 跨來源比對——只有某一家落後，就是那一家在失敗，不必猜原因。
- 錯誤型別已指出責任歸屬，先看型別再查：Antigravity `invalidUsage` 代表 CLI 有跑且有回應（**不是** sandbox 或路徑問題），`binaryNotFound`／`backgroundReadFailed` 才是。
- live read 沿外層診斷規則；Antigravity 真實讀取只由 App 執行官方 CLI。
- token、auth.json、完整帳號 ID、email、fingerprint、OAuth URL／state、私人狀態不得進 repo 或外部服務；
  規則檔／commit message 不記帳號 label，驗收僅輸出去識別的必要資料。
- 讀系統 `~/.codex/auth.json`（`CodexActiveAccount`）只取 `tokens.account_id` 算指紋即丟；
  同檔的 token 不得讀出、記錄或存檔。App 未開 App Sandbox（`project.yml` 有註解說明原因），
  讀得到不代表可以讀更多。
- 更換模型、prompt、安全旗標或放寬重送次數需明確同意；固定值以外層規則為準。
- Rust 退役須全部驗收通過，再盤點實際 App／啟動入口，列具體清單供確認；
  舊 App／資料移入 `mktemp -d` 備份，不用 `rm -rf`，共用資料目錄保留。

## 8. 進度與續作入口（2026-09-14）

進度以 `git log` 為準，本節不釘 hash。已提交：子程序隔離、鎖回收與 heartbeat、共用 `ClaudeCooldown`、
engine snapshot 直送 UI、/simplify 清理、Antigravity 5h 依方案選配。最新驗證：**1245 tests、1 skipped、
0 failures**，`make build-ci`／簽章／Universal 通過，產物已啟動並實機確認 Antigravity 恢復讀取。
外層 repo 的 Rust Antigravity 亦已提交（147/147、fmt／clippy／release 通過，真實 poke 未驗收），其
`.gitignore` 已排除巢狀 `khih/` 與 `AGENTS.md.bak-*`。

**守護目前關閉**：`quotaKeeperEnabled` = 0（持久化，使用者決定）。重開前必須取得明確同意；手動 5h／
立即檢查與既存預約仍是主動路徑，唯讀驗收時不要按。

| 已實作／驗證 | 證據與界線 |
|---|---|
| 引擎移植、ring／分組、5h、動畫、lock／清理／process group | fake backend／parser／controller、互動 motion、競爭 lock、save failure、parent＋child timeout 測試；不等於真實 poke |
| Antigravity 讀取 | 實機確認免費方案（僅每週）可解析、5h 缺席不物化、headline 退回 weekly |
| Claude auth | 拒絕／過期／401 已分流；實機仍見 Keychain `OSStatus -25293`，靠 CLI fallback 供值 |

續作先核對**實際執行版本、授權、keeper／預約／cached 狀態**，再處理：
- **開啟守護＝第一次真實 Antigravity poke**：兩組週視窗 0%、倒數未啟動、reset 隨觀測後移，需明確同意。
- Claude 鑰匙圈明確授權／官方登入更新後，真實讀值是否恢復；程式錯誤修正不等於憑證有效。
- 新版 Dock／hover 開關、多螢幕、VoiceOver、高對比、Reduce Motion／Transparency、idle CPU 實機驗收。
- 睡眠喚醒、真實取消／timeout 依先前決定擱置。**Rust 不可宣告可退役**，外層規則尚未搬入。
- 已決定另案（實機驗收後再做）：`QuotaBackend` 加 `cooldownDeadline`；outcome 帶回 persisted snapshot 取代手抄 allowlist；process group 推廣到其餘四個手刻 `Process()`。
