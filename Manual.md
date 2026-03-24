# Hub 操作手冊（範例：`coolapp`、本機埠 **5654**）

以下命令都在專案根目錄（本倉庫 **`WebTunnelHub`**）下執行。

**Windows**：請在 **Git Bash**、**WSL**，或任何含 **`bash`** 與 **`ssh`** 的環境執行下方相同的 **`./hub-*.sh`**（需安裝 OpenSSH；Git for Windows 通常已含）。`.env` 的 **`SSH_KEY`** 可用正斜線路徑，例如 **`C:/Users/you/.ssh/key.pem`**。

---

## 應用（App）生命週期

一個 **Hub 應用** 指：在 EC2 的 Caddy 上有一個 **`應用名.根域:埠`** 站點（子域），且本機有一條 **`ssh -R`** 把 EC2 上對應回環埠轉到本機某 HTTP 服務。建議依序理解為下列階段。

| 階段 | 說明 | 典型命令／狀態 |
|------|------|----------------|
| **0. 前置** | 專案根目錄具備 **`.env`**（或等效 **`export`**），內容符合 `hub-common.sh` 必填變數 | `cp .env.example .env` 並編輯 |
| **1. 註冊（一次性）** | 在 EC2 寫入 **`${HUB_DIR}/<AppName>.caddy`** 並 **`caddy reload`**；**不**建立 SSH；**應用名須全小寫**；**必須** **`--note` / `-n`**，且經清理後至少含 **5 個英文字母**（A–Z / a–z） | `./hub-register.sh [--force] --note '說明' <AppName>` |
| **2. 本機服務** | 本機 HTTP 監聽（例如 **`serve.py`**），埠須與隧道一致 | `PORT=5654 python3 serve.py` |
| **3. 隧道（常駐）** | 本機執行 **`hub-tunnel.sh --port <本機埠> <AppName>`**，讓 EC2 **`127.0.0.1:<遠端埠>`** 連到本機 | 終端保持開啟或改 **`nohup`** 等 |
| **4. 運行中** | 瀏覽器開 **`https://<AppName>.<根域>:<埠>/`**（由 **`HUB_PUBLIC_URL`** 解析根域與埠）；斷線／休眠會中斷對外服務 | **`./hub-status.sh`**：已註冊名、本機 **`ssh -R`**、由埠反查的隧道名、EC2 監聽、Caddy 路由（含註冊說明） |
| **5. 暫停** | 關掉本機 **`hub-tunnel`**（與可選關 **`serve.py`**）；EC2 上 **Caddy 片段可保留**（下次只重開隧道） | Ctrl+C 或殺 **`ssh`** |
| **6. 註銷（下架）** | 刪 EC2 路由檔並 reload；預設一併殺本機對該埠的 **`ssh -R`** | `./hub-unregister.sh <AppName>` |

**根站（非子路徑）**：不帶應用名執行 **`./hub-tunnel.sh`**，將本機 **`PORT`／8080** 對到 EC2 **`127.0.0.1:10080`**，由主 **`Caddyfile`** 的 **`handle`** 接 **`/`**；無需 **`hub-register.sh`**。

```mermaid
flowchart LR
  subgraph prep [前置]
    E[".env 必填變數"]
  end
  subgraph once [每個新 App 一次]
    R["hub-register.sh（小寫名；必填 --note）"]
  end
  subgraph run [常駐]
    S["本機 HTTP\nserve.py 等"]
    T["hub-tunnel.sh\n--port … App"]
  end
  subgraph end [下架]
    U["hub-unregister.sh"]
  end
  prep --> R --> S --> T
  T --> U
```

---

## 0. 遠端設定（`.env`）

複製範本後編輯 **`SSH_KEY`**、**`SSH_TARGET`** 等（所有 Hub 腳本經 **`hub-common.sh`** 自動載入）：

```bash
cp .env.example .env
# 編輯 .env：至少設定 SSH_KEY、SSH_TARGET；HUB_PUBLIC_URL 需與瀏覽器實際 HTTPS 前綴一致
```

**必須**填好 **`.env.example`** 裡每一項（或等效的 **`export`**）；**`hub-common.sh` 已無預設值**，缺任一變數腳本會直接報錯退出。

手冊範例網址假設 **`HUB_PUBLIC_URL=https://db.xception.tech:1080`**。

---

## 1. 註冊 `coolapp`（只做一次）

本機服務要先在 **`http://127.0.0.1:5654`** 跑得起來；註冊只是把 **EC2 上 Caddy 的路由**寫好。

**`hub-register.sh` 只接受全小寫應用名**（見 **`hub_validate_register_app_name`**／**`hub-common.sh`**）；含大寫會直接失敗。

```bash
cd /path/to/WebTunnelHub
# --note 必填；清理後須含至少 5 個英文字母。hub-status 會在路由列末尾顯示 # …
./hub-register.sh --note 'TRS001 laptop wiki link' coolapp
```

**不可**省略 **`--note`**／**`-n`**；說明經 **`hub_sanitize_register_note`** 後須仍含至少 **5 個英文字母**（純數字或符號會被拒絕）。

- 若顯示**已存在**而結束（exit **2**），代表註冊過了，**不必**再跑；若要覆寫才用 **`./hub-register.sh --note '…' --force coolapp`**（**`--force`** 與 **`--note`** 均須寫在 **`<AppName>`** 之前）。

---

## 2. 開隧道（要一直開著）

**一鍵（本機 Hello + 隧道）**：在同一終端先起 **`serve.py`** 再起 **`hub-tunnel.sh`**（隧道在前台，**Ctrl+C** 會一併停掉本機服務）：

```bash
cd /path/to/WebTunnelHub
./hub-serve-tunnel.sh --port 5654 coolapp
# 根站（無子域應用名）：
# ./hub-serve-tunnel.sh
```

---

另開終端（或背景跑），**應用名須與註冊時相同**（檔名／子域一致；若曾用舊版註冊出現大小寫混用，隧道名須對應磁碟上的 **`.caddy`** 檔名）。

```bash
cd /path/to/WebTunnelHub
./hub-tunnel.sh --port 5654 coolapp
```

（亦可：`./hub-tunnel.sh coolapp --port 5654`）

**背景執行（`nohup` + 日誌）**：`./hub-tunnel.sh -b --port 5654 coolapp`，日誌預設 **`logs/hub-tunnel-coolapp.log`**（見 **`SETUP.md` 第十一節 · 11.6**）。**Linux / macOS** 亦可改用 **systemd user**、**LaunchAgent** 或 **autossh**。**Windows** 建議 **Git Bash 的 `-b`**、**工作排程器**，或在 **WSL** 內用與 Linux 相同方式；避免 **Windows 原生 ssh** 與 **Git Bash 腳本**混用導致 **`hub-status.sh`** 對不到行程。

---

## 3. 瀏覽器

```text
https://coolapp.db.xception.tech:1080/
# 根域與埠來自 HUB_PUBLIC_URL，例如 HUB_PUBLIC_URL=https://db.xception.tech:1080
```

（建議網址結尾加 **`/`**；DNS 須有 **`coolapp.db.xception.tech`** 或泛解析 **`*.db.xception.tech`**。）

---

## 4. 查詢

**只看已註冊的應用名稱：**

```bash
./hub-applist.sh
```

**本機隧道 + EC2 監聽 + Caddy 路由一覽：**

```bash
./hub-status.sh
```

**快速自檢（設定、SSH、可選本機 HTTP、公網 URL 提示）：**

```bash
./hub-doctor.sh
./hub-doctor.sh coolapp
./hub-doctor.sh --port 5654 coolapp
```

**`hub-status.sh`** 區塊標題與說明為英文。一次 SSH 讀回 **`${HUB_DIR}/*.caddy`** 後會顯示：

1. **已註冊的應用名**（來自檔名；畫面上為小寫排序，實際檔名大小寫與 **`hub_remote_port`** 雜湊一致）。
2. 本機指向 **`SSH_TARGET`** 且含 **`-R`** 的 **`ssh`** 行程。
3. **本機活動隧道名**：由 **`-R`** 的遠端埠對照 **`hub_remote_port`** 反查（**`10080`** 顯示為 **`default`**）；若註冊時用 **`REMOTE_PORT`** 覆寫埠，可能顯示「未匹配」。
4. EC2 上 **10080** 與 **20000–29999** 相關 **LISTEN**。
5. **Caddy 子域路由**：每行 **`reverse_proxy`** 摘要；若片段含 **`# Registration note:`** 註解（由 **`hub-register.sh --note`** 寫入），會在行末以 **`# …`** 附帶顯示。

底部「解读」有各欄位說明。

---

## 5. 註銷 `coolapp`（刪路由 + 停本機 SSH）

在**當初跑 `hub-tunnel.sh` 的那台電腦**執行：

```bash
./hub-unregister.sh coolapp
```

- 會刪 EC2 上的 **`hub-routes/coolapp.caddy`**（**大小寫不敏感**比對；若曾留下 **`CoolApp`**／**`coolapp`** 兩個檔會一併刪）並 **reload Caddy**。  
- 會結束本機對應的 **`ssh -R`**；當時前台的 **`./hub-tunnel.sh`** 會跟著**錯誤退出**，屬正常。  
- 只刪設定、不殺 SSH：`./hub-unregister.sh --no-kill coolapp`

---

## 共用環境變數（`hub-common.sh` / `.env`）

腳本會自動 **`source`** 專案根目錄的 **`.env`**（若存在）。下列變數**皆必填且不得為空字串**（可改在 shell 內 **`export`** 覆寫）。

| 變數 | 用途 |
|------|------|
| **`SSH_TARGET`** | SSH 目標，例如 **`ubuntu@example.com`** |
| **`SSH_KEY`** | 本機私鑰路徑（**`-i`** 傳給 **`ssh`**） |
| **`SSH_PORT`** | SSH 埠（數字，例如 **`22`**） |
| **`HUB_DIR`** | EC2 上 Hub 片段目錄（例如 **`/etc/caddy/hub-routes`**），內含 **`*.caddy`** |
| **`MAIN_CFG`** | EC2 上 Caddy 主設定路徑（例如 **`/etc/caddy/Caddyfile`**），佈局須與 **`Caddyfile.ec2.example`** 一致：根站點塊 + **頂層** **`import ${HUB_DIR}/*.caddy`** |
| **`HUB_PUBLIC_URL`** | 根站 HTTPS URL（**無尾隨路徑**），例如 **`https://db.xception.tech:1080`**；腳本由此解析主機名與埠，應用網址為 **`https://<AppName>.<該主機名>:<埠>/`** |

**應用名規則**

- **`hub-tunnel.sh` / `hub-unregister.sh`**（**`hub_validate_app_name`**）：長度最多 **48** 字元；第一字元須為英文或數字；其餘可為英文、數字、**`_`**、**`-`**。正則概念：`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$`。
- **`hub-register.sh`**（**`hub_validate_register_app_name`**）：在上述規則外，**須全小寫**（不得含大寫英文字母），以免同一邏輯名稱因大小寫不同產生兩份 **`.caddy`** 與兩個遠端埠。

**Hub 遠端回環埠（預設）**：`20000 + (zlib.adler32(應用名 UTF-8 位元組) mod 10000)`，落在 **20000–29999**（**與字串大小寫有關**）。本機預覽：

```bash
python3 -c "import zlib; n=b'coolapp'; print(20000+zlib.adler32(n)%10000)"
```

若曾用 **`REMOTE_PORT`** 覆寫，**註冊／隧道／註銷**時須使用**相同**覆寫值，且 Caddy 片段內 **`reverse_proxy`** 埠須一致。

---

## 各工具參數與環境變數詳解

### `hub-register.sh`

在 EC2 建立 **`${HUB_DIR}/<AppName>.caddy`**（獨立站點塊 **`<AppName>.<主機名>:<埠> { reverse_proxy … }`**），必要時建立 **`_keep.caddy`**，然後 **`caddy validate` + `systemctl reload caddy`**。**不會**停止或修改既有 SSH。

**應用名**須通過 **`hub_validate_register_app_name`**（**`hub-common.sh`**）：**全小寫** + 上節字元規則。

**語法：**

```text
./hub-register.sh [--force] --note|-n <text> <AppName>
```

**`<AppName>`** 須為最後一個參數；**`--force`**、**`--note`**／**`-n`** 皆須寫在其**之前**。多餘參數會報錯。

| 參數 | 說明 |
|------|------|
| **`--force`** | 可出現多次（效果同單次）。若遠端已有 **`${AppName}.caddy`**，預設**失敗退出**；加 **`--force`** 則覆寫該檔並 reload。 |
| **`--note` / `-n`** | **必填**。註冊說明，寫入片段頂端 **`# Registration note: …`**；**`hub-status.sh`** 在路由摘要行末以 **`# …`** 顯示。經 **`hub_sanitize_register_note`** 後須含至少 **5 個英文字母**（A–Z / a–z）；換行與 Tab 會改空白，最長約 **1024** 字元。 |
| **`<AppName>`** | 路徑段名稱；**僅小寫**，規則見上節。 |

| 環境變數（可選） | 說明 |
|------------------|------|
| **`REMOTE_PORT`** | 覆寫寫入 Caddy 片段的 **`reverse_proxy 127.0.0.1:埠`**；未設則用 **`hub_remote_port(AppName)`**。之後 **`hub-tunnel`**／**`hub-unregister`** 須一致。 |

**結束代碼：** **`0`** 成功；**`1`** 用法錯誤、SSH／Caddy 失敗；**`2`** 遠端路由已存在且未使用 **`--force`**（**不**改 Caddy、**不**動 SSH）。

---

### `hub-tunnel.sh`

建立 **`ssh -N`** 反向轉發：**`EC2 ${REMOTE_BIND}:${REMOTE_PORT}` → 本機 `127.0.0.1:${LOCAL_PORT}`**。程式會**一直佔用該終端**，直到連線中斷或被殺。

**語法：**

```text
./hub-tunnel.sh [--port <本機埠> | -p <本機埠>] [<AppName>]
./hub-tunnel.sh [--help | -h]
```

| 參數 | 說明 |
|------|------|
| **（無應用名）** | **根站模式**：本機 **`LOCAL_PORT`**（見下）→ EC2 **`127.0.0.1:10080`**（**`REMOTE_PORT`** 預設 **10080**）。 |
| **`<AppName>`** | **Hub 應用模式**：本機 **`LOCAL_PORT`** → EC2 **`127.0.0.1:<REMOTE_PORT>`**；**`REMOTE_PORT`** 預設由應用名推算。 |
| **`--port` / `-p`** | 本機 HTTP 服務埠；未指定時 **`LOCAL_PORT`** 取自環境變數 **`PORT`**，再預設 **8080**。 |
| **`--help` / `-h`** | 印出用法後以 **`0`** 退出。 |

**參數順序：** **`--port`** 與 **`<AppName>`** 可互換（先解析旗標再收單一位置參數）。

| 環境變數（可選） | 說明 |
|------------------|------|
| **`PORT`** | 無 **`-p/--port`** 時的本機埠（預設 **8080**）。 |
| **`REMOTE_BIND`** | SSH **`-R`** 在 EC2 上的綁定位址，預設 **`127.0.0.1`**。設 **`0.0.0.0`** 可讓非本機連線打到該埠（需 **`sshd`**／防火牆允許；常與直連 HTTP 測試一併討論，見 **`SETUP.md`**）。 |
| **`REMOTE_PORT`** | 覆寫 EC2 側轉發埠。Hub 模式預設為 **`hub_remote_port(AppName)`**；根站模式預設 **10080**。 |

**結束代碼：** 誤用參數為 **`1`**；成功則**不返回**（**`exec ssh`**），直到 SSH 結束。

---

### `hub-unregister.sh`

預設：殺本機轉發到 **`127.0.0.1:<REMOTE_PORT>`** 的 **`ssh -R`**（與 **`hub_kill_tunnels_for_remote_port`** 邏輯一致），再刪遠端 **`${HUB_DIR}/<AppName>.caddy`** 並 **`caddy validate` + reload**。

**語法：**

```text
./hub-unregister.sh [--no-kill ...] <AppName>
```

| 參數 | 說明 |
|------|------|
| **`--no-kill`** | 可重複。若指定，**不**殺本機 SSH，只刪遠端片段並 reload（自行停 **`hub-tunnel.sh`**）。 |
| **`<AppName>`** | 要移除的應用名；**`REMOTE_PORT`** 預設與該名對應，見下。 |

| 環境變數（可選） | 說明 |
|------------------|------|
| **`REMOTE_PORT`** | 與註冊／隧道時相同；用於比對本機 **`ssh -R … 127.0.0.1:${REMOTE_PORT}:…`**。若註冊時曾覆寫埠，此處**必須**同樣覆寫。 |

---

### `hub-status.sh`

**無命令列參數。** 需能 **`BatchMode`** SSH 登入 EC2。對 **`${HUB_DIR}/*.caddy`**（略過 **`_keep`**）**只做一次**遠端採集，再於本機組版，大致順序為：

1. **已註冊應用名**（來自 **`.caddy`** 檔名；列表為小寫排序，實際檔名大小寫與 **`hub_remote_port`** 一致）。
2. 本機含 **`-R`** 且目標主機為 **`SSH_TARGET`** 的 **`ssh`** 行程。
3. **活動隧道名**：解析 **`-R`** 遠端埠；**`10080`** 對應根站 **`default`**；其餘埠與已註冊名稱的 **`hub_remote_port`** 比對（同埠可能對應多個僅大小寫不同的舊檔名時會並列）。曾用 **`REMOTE_PORT`** 覆寫者可能無法對上。
4. EC2 上 **10080** 與 **20000–29999** 區間相關 **LISTEN**（**`127.0.0.1`**）。
5. **Caddy 子域路由**：每個片段的 **`reverse_proxy`** 首行摘要；若檔案含 **`# Registration note:`**（**`hub-register.sh --note`**），附於該行末尾 **`# …`**。

底部「解读」說明各欄位與限制。

**Windows（Git Bash）：** **`hub-common.sh`** 會把 **`/usr/bin`** 放到 **`PATH`** 前面，避免 **`sort -u`** 誤用 **`sort.exe`**（曾導致已註冊名稱區塊異常與尾端亂碼錯誤）。本機 **`ssh`** 列會同時匹配 **`ssh.exe`**。若仍顯示「本機無 **`-R`**」但 EC2 有 **LISTEN**，多半是隧道在**另一台電腦**上，或 **`ssh`** 由非 Git Bash 環境啟動且 **`ps`** 看不到完整命令列。

---

### `hub-applist.sh`

**無命令列參數。** 從 EC2 的 **`${HUB_DIR}`** 列出所有 **`.caddy`** 檔名（去掉副檔名），排除 **`_keep`**，每行一個、不分大小寫排序。若無應用，向 **stderr** 印提示並以 **`0`** 結束。

---

### `hub-ssh.sh`

互動式登入與 **`hub-tunnel`** 相同的 **`SSH_TARGET`**（**`-t`** 配置 tty）。

**語法：** **`./hub-ssh.sh`**（無額外參數）。

| 環境變數（可選） | 說明 |
|------------------|------|
| **`REMOTE_CMD`** | 遠端執行的指令字串；預設 **`cd ~/webTunnel && exec bash -l`**。改為 **`bash -l`** 等可避免硬編目錄。 |

---

### `serve.py`（本機 HTTP，與 Hub 搭配）

專案內典型用法：**一個應用一個埠**，再 **`hub-tunnel.sh --port 該埠 應用名`**。

- **`/`**：輕量首頁（**`hub_wait_local_http`** / 健康檢查用，不跑 SSH）。  
- **`/status`**：執行同目錄 **`hub-status.sh`**（需 **`bash`**、專案根 **`.env`**），將終端輸出以 **`<pre>`** 顯示；每次重新整理頁面會再跑一次（可設 **`HUB_STATUS_REFRESH_SEC`** 自動刷新，見 **`SETUP.md`**）。

| 環境變數（可選） | 預設（見 **`SETUP.md`**） | 說明 |
|------------------|---------------------------|------|
| **`PORT`** | **8080** | 監聽埠。 |
| **`HOST`** | **127.0.0.1** | 綁定位址。 |
| **`HELLO_TITLE`** | **WebTunnelHub** | 首頁與狀態頁標題（已做 HTML 跳脫）。 |
| **`HUB_STATUS_TIMEOUT`** 等 | 見 **`SETUP.md`** | **`/status`** 與 **`HUB_BASH`**（Windows 建議 Git Bash 環境）。 |

---

## 延伸閱讀

- **`SETUP.md`**（簡體）：從零安裝 EC2 **Caddy**、安全組、**`hub-register` 小寫名與必填 `--note`（至少 5 個英文字母）**、**`hub-status.sh` 五段輸出（英文）**、重開機恢復與清單；路徑範例為 **`WebTunnelHub`**。
- 與本手冊分工：**`Manual.md`** 偏逐步操作與參數表；**`SETUP.md`** 偏架構圖與首次佈署。
