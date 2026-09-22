# Quota 安全契約

原外層 Rust 專案 AGENTS.md §2–§4 的保留內容。Swift 的實作與較新的已決策事項以專案 AGENTS.md 為準。

## 2. 不可破壞的 quota 安全不變量

- 第一次觀測、v1 state 重建、沒有舊 fingerprint、fingerprint 改變時，只建立 baseline，不得 poke。
- 分開保存與 ratchet 5 小時／每週 window。**自動路徑（reset 偵測 → poke transaction）只能 poke 唯一的 Codex `codex` 7 天 window、Claude `claude:seven_day`，或 Antigravity 的 `antigravity:{gemini,claude_gpt}` 7 天 window**；Claude 其他週視窗永遠唯讀。
- 5 小時 window 只能由**使用者明確動作**啟動（toolbar 按鈕或使用者設定的單次預約），實作在 `MonitorEngine::start_five_hour()`；`detect_reset()` 永不得以 5 小時為 target。放寬成自動或週期性重複前需明確同意。
- 5 小時啟動**單次不重試**（`attempt` 恆為 1）。Codex／Claude 五道閘門任一不過就 `Refused` 且不送請求：已有 baseline、fingerprint 存在且未變、5 小時 window 唯一存在、`usedPercent` 非 unknown、倒數尚未啟動。Antigravity 逐群組套用 baseline、唯一 300 分鐘 window、非 unknown、倒數未啟動四道閘門。
- 單次 weekly check 最多 `POKE_ATTEMPT_LIMIT = 3`。只有 weekly `usedPercent == 0` 且倒數未錨定時可重送。
- 自動 check 以 `lastHandledResetKey` 防止同一 reset 每 5 分鐘重送。第一個 poke process 失敗時不得寫 reset key。
- 手動 check 不是繞過閘門的後門：同樣要有安全 baseline、weekly 0%、倒數未錨定，且 Claude 第一次缺席不得 poke。
- 不得只因預定 reset time 已過、外部公告、CLI exit 0、stdout `OK` 或 response 完成就宣告 reset／成功。
- 必須保留 delayed reset、`pendingScheduledResetAt`、`lastHandledResetKey`、`accountFingerprint`、unknown usage、per-account `check.lock` 與 atomic state write。
- 若其他使用已啟動新倒數，不得再 poke。`verified` 才能顯示為自動啟動；`unverified`／`not-attributed` 只能警告。
- `@thsottiaux` X 貼文只供 Codex weekly advisory 顯示，永不觸發 poke。
- Google Antigravity 的 startup／timer check 可執行分組 weekly reset transaction 與 burn-rate；5 小時仍只能由使用者明確按下工具列按鈕或設定單次預約逐群組啟動。每組 5 小時或 weekly transaction 都最多一個固定最小請求、不重試；單組失敗不得阻止後續組。
- token、`auth.json`、完整 account ID、email 與 Application Support 私人狀態不得進 repository 或外部服務。
- 更換模型、prompt、安全旗標或放寬重送次數前，必須取得使用者明確同意。
- **使用者要求與本節不變量衝突時的處理順序**（2026-08-30 5 小時功能即依此完成）：①明說衝突點與真實代價，不要靜默實作也不要直接拒絕 ②用具體選項取得同意 ③**收窄**不變量而非刪除（保留「自動路徑禁止」，只開放使用者明確動作）④程式與本檔**同批提交**。只改程式不改本檔，下個 session 會把它當違規改掉。

固定最小請求：

- Codex：`gpt-5.6-luna`、`model_reasoning_effort="low"`、`--ephemeral`、`--sandbox read-only`、`approval_policy="never"`；prompt：`Use the shell tool to run /usr/bin/true exactly once. Then reply only: OK`。
- Claude：`claude-haiku-4-5-20251001`、`--safe-mode`、`--tools ""`、`--setting-sources ""`、`--strict-mcp-config`、`--no-session-persistence`、`--max-budget-usd 0.05`；prompt：`Reply with exactly: OK`。送出前清除 API key、Bedrock、Vertex 計費環境變數；不得自行呼叫 OAuth refresh endpoint。
- Antigravity：Gemini 群組 `gemini-3.8-flash-low`、Claude／GPT 共用群組 `claude-sonnet-4-6`；prompt：`Reply with exactly: OK. Do not use tools.`；固定 A1 旗標：`-p --effort low --mode plan --sandbox --disable-slash-commands --output-format json --print-timeout 120s`。只能使用這兩個官方 `agy` model ID；不得額外對 GPT 發送第三次請求。

## 3. Provider backend 契約

### 3.1 Codex

- `account/rateLimits/read` 是 quota 主證據；`secondary` 可能是 7 天 window。完整保存 `rateLimitsByLimitId`；缺少才 fallback `rateLimits`。
- 同一 `resetsAt`（±2 秒）下的非零下降讀值是落後副本：永久保留較高值，只更新 `observedAt`。0% 可接受；reset time 移動或讀值升高立即接受。不得加入「連續 N 次後接受下降」逃生門。
- `resetsAt` 會 ±1 秒抖動；只能用 `reset_at_moved()`／`RESET_AT_JITTER_SECONDS = 2`，不得嚴格比較。
- `rateLimitReachedType`、`spendControlReached` 不可靠；credits、individual limit、reset credits 只讀顯示。`account/usage/read` 沒有 quota 百分比。
- Reset credit 以 `rateLimitResetCredits.availableCount` 顯示數量；到期日只能取 optional `credits[]` 中 `status == "available"` 的最早 `expiresAt`。只有 count、沒有明細時明說「後端未提供到期時間」，不得推算或把 `grantedAt` 當期限。詳情頁顯示台北時間與剩餘時間，7 天內用 warning 色；tray 有期限才附最早到期。
- 真實案例證明 process 成功仍可能長時間 0%／provisional：activity attempt 完成只代表請求完成；`lastPoke.status` 才代表 attribution。

### 3.2 Claude Code

- `accounts.json.label` 只是使用者可改的顯示名稱，不是登入證據；不得從卡片 label 推論實際帳號。先以 `claude auth status --json` 的 `orgId + email` 算同規格 fingerprint 與 state 比對，只輸出 match／mismatch，不輸出原始 email；本專案仍只支援系統單一 Claude 登入。
- `claude auth status --json` 只用於登入身分與方案，不會刷新過期 access token。即使 logged in，`GET /api/oauth/usage` 仍可能 401。
- 過期時提示使用者用官方 Claude CLI 成功取得一次模型回覆；由 CLI 更新 Keychain。App 不得接管 refresh-token rotation。
- 憑證來源為 Keychain `Claude Code-credentials`，失敗才 fallback `~/.claude/.credentials.json`；不得輸出 token。
- `/api/oauth/usage` request 必須帶 `User-Agent: claude-code/<version>`；version 每次由本機官方 `claude --version` 解析，不得硬編或另打網路。缺 header 會落入嚴格限流 bucket，曾造成資料約 19 小時未更新並連續收到 429；fake HTTP tests 必須逐次驗證 header。
- 真實 Pro baseline 已確認 usage 尺度為 0–100，主要欄位為 `five_hour`／`seven_day`，映射 300／10080 分鐘。parser 仍接受既有多種欄位名與 epoch seconds／milliseconds／RFC3339。
- Pro 實測未回報額外週視窗，但不得假設所有方案都沒有。額外視窗缺席時不建立 bucket。
- 主要 window 缺席會物化為 0%／`resetsAt: None`。第一次缺席只記 pending；下一次仍缺席且既有預定 reset 已過，才可進 poke transaction。短暫漏報恢復不得 poke，手動 check 也不得繞過。
- 首次自然 timer check 只建立 baseline；`pendingScheduledResetAt`、`lastHandledResetKey`、`lastPoke` 保持空值。
- HTTP 429 不是帳號失效：尊重整數秒或 HTTP-date `Retry-After`，缺少／無法解析時冷卻 15 分鐘。持久化 `checkCooldownUntil`、保留 cached snapshot；冷卻內 startup／timer／manual 都不得碰 fingerprint 或 usage backend，也不得重複寫 activity。首次 429 只記一筆，UI 顯示黃色提示；`CheckOutcome::RateLimited` 必須明說「未連線」，不得誤報完成。下一次成功讀取才清空冷卻；禁止立即重試或把 429 當紅色致命錯誤。
- **Claude 的 `not-attributed` 通常是正確結果，不是 bug。** 真實使用可能先啟動 window；不得為了讓結果變成 `verified` 而放寬 `POKE_WINDOW_START_TOLERANCE_SECONDS`。
- Claude 的 `resetsAt` 觀察到落在整分鐘、Codex 為秒級（3 筆樣本，不足以斷言）。若成立，分鐘對齊最多造成 59 秒偏差，已逼近 60 秒容忍值 — **Claude 的 `verified` 天生比 Codex 脆弱**。調整容忍值需先累積「確定無其他使用」的觀測並取得同意。

### 3.3 Google Antigravity

- 登入與 OAuth 完全由 Google 官方 `agy` 管理；App 不讀 token、email、project ID、Antigravity 私人設定或 OMP SQLite，也不自行呼叫 refresh endpoint。
- 第一版只支援系統中單一官方 Antigravity CLI 登入。額度唯一證據為 `agy -p /usage --output-format json` 的成功 envelope 與 tab-separated response；缺每週列、重複列、百分比超界或 timestamp 無法解析時整次拒絕。**缺 5 小時列不是格式錯誤**，見下條。
- 官方實測只有兩個共享模型群組：`Gemini Models` 與 `Claude and GPT models`。每組必有 `Weekly Limit Remaining`，映射 secondary 10080 分鐘；`Five Hour Limit Remaining` **視方案而定**，有才映射 primary 300 分鐘。remaining 轉為 used。2026-09-14 實測：無 Gemini Pro 訂閱時兩組都只回傳每週列。缺席時 primary 留空，**不得物化成 0%**——那會憑空造出沒有來源的倒數；續訂後該列會回來，因此不得移除 5 小時的解析與顯示路徑。
- 0% window 不因存在 reset time 就宣告已啟動；仍由 `countdown_window_active()`、前後 observation 與 backend verification 判定。不得因 CLI exit 0、`status=SUCCESS` 或完整 window timestamp 宣告 poke 成功。
- 每組獨立保存 5 小時 starter、weekly keeper 與 burn-rate。weekly reset 自動路徑依 Gemini、Claude／GPT 順序處理；成功送出後先 atomic 寫該組 `weeklyKeeper.lastPoke.status = unverified` 與 reset key，再共用 `verify_poke(PokeTarget::AntigravityGroup)` 做 3 次 backend 驗證與 60 秒歸因。
- 使用者明確啟動 5 小時時依相同兩組順序處理；已啟動略過，missing／duplicate／unknown 拒絕。Claude 與 GPT 共用額度，永遠只送 Claude 代表模型一次。

## 4. Reset、倒數與 poke transaction

- Codex target：唯一 `limitId == "codex" && windowDurationMins == 10080`；Claude target：唯一 `limitId == "claude:seven_day"`。缺少、重複、duration unknown 時禁止 poke。
- `usedPercent > 0` 且未來 `resetsAt` 代表倒數已啟動。0% 只有在 reset time 穩定，或能推回已過去的固定 start，才算錨定；隨觀測後移的完整 window 是 provisional。
- 所有倒數判定集中在 `countdown_window_active()`；UI、monitor、verification 不得另寫寬鬆版本。
- `CheckMode::Live` 只供 startup／timer，其餘使用者發起的檢查一律 `Manual`。5 小時啟動不是 `CheckMode`，走獨立的 `start_five_hour_all()`；Antigravity 5 小時也只能從這條明確動作路徑進入。三條路徑共用 `check.lock`、Coordinator 單飛與取消 token；單一帳號或 Antigravity 單一群組失敗不得阻止後續項目。
- 5 小時與每週共用泛化的 `verify_poke(PokeTarget)`。**不得另寫驗證**：Codex 未啟動的 5 小時 window 是 `resetsAt = observedAt + 5h`，反推起點等於讀取時刻，`poke_matches_window()` 單獨會把它誤判為 `verified`；只有 `verify_poke` 的「倒數已確認」前置條件（`usedPercent > 0` 或連兩次穩定 0%）擋得住。

Transaction 順序不可改：

1. 由 backend 證據確認 reset 或符合手動安全條件，先排除其他使用已啟動倒數。
2. 檢查 `lastHandledResetKey`。
3. `poke()` 成功後先 atomic 寫 reset key 與 `lastPoke.status = "unverified"`。
4. 做 3 次 backend 驗證，每次間隔 2 秒。
5. window start 與 poke time 在 60 秒內才 `verified`；未錨定維持 `unverified`，無法歸因則 `not-attributed`。
6. 儲存最新 snapshot／keeper；單一帳號失敗不得阻止後續帳號。
