# 从零搭建：Hello World + EC2 反向 SSH 隧道 + HTTPS（Caddy Hub）

本文说明如何从空白环境搭好一条完整链路：**本机**运行一个或多个 Hello World（或其它 Web 服务），通过 **SSH 反向隧道** 接到 **EC2**，再由 **Caddy** 在 `**https://你的域名:1080`** 上对外提供 **HTTPS**，并支持 **子域分流**（Hub：`**应用名.你的域名:1080**`）。

**本机或 EC2 重启后怎么重新连上？** 见 **第十一节（初学者：重启后恢复）**。

---

## 一、整体架构（HTTPS 在 1080 + Hub）

```
浏览器 --HTTPS--> EC2:1080 (Caddy：TLS + 按 Host 反代)
        |                |
        |                +--> 127.0.0.1:10080 ──SSH──> 本机 :8080   （根站：域名:1080 /）
        |                +--> 127.0.0.1:<自动端口> ──SSH──> 本机 :<各应用端口>  （CoolApp.域名:1080 …）
        v
https://域名:1080/              → 默认隧道 10080
https://CoolApp.域名:1080/      → 该应用专用回环端口（由应用名稳定算出）
```

要点：

- 浏览器只和 **Caddy** 建立 TLS；证书域名一般为 `**db.xception.tech`**（请换成你的域名）。
- **1080** 由 **Caddy** 监听；**不要**再用 `**ssh -R 0.0.0.0:1080`** 占同一端口。
- **根站**：`./hub-tunnel.sh`（无应用名）→ EC2 `**127.0.0.1:10080`** → 本机 `**127.0.0.1:8080**`（可改 `PORT`）。
- **子域应用**：DNS 需 `**应用名.db.xception.tech**`（或 `***.db.xception.tech**` 泛解析）指向 EC2；每个应用 `**./hub-register.sh 应用名`**（EC2 上写独立 `**站点块**`）+ `**./hub-tunnel.sh --port 本地端口 应用名**`（长期开着）。

---

## 二、你需要准备的东西


| 项目          | 说明                                               |
| ----------- | ------------------------------------------------ |
| EC2（Ubuntu） | 有公网 IP，安全组放行 **22**、**80**、**1080**（见下文）         |
| 域名          | 根域如 **db.xception.tech** 的 **A** 指向 EC2；每个应用为子域（如 **CoolApp.db.xception.tech**），各子域 **A** 或泛解析 `*.db.xception.tech` 指向同一 IP |
| SSH 登录      | 用户如 `ubuntu`，私钥路径本仓库脚本里默认可改为你的路径                 |
| 本机          | Python 3，可长期开着终端跑 `serve.py` 与 `hub-tunnel.sh`       |


**安全组建议（入站）：**

- **TCP 22**：仅你的 IP 或跳板（SSH 管理）。
- **TCP 80**：Let’s Encrypt **HTTP-01** 验证与证书续期（我们实际 issuance 曾走 80）。
- **TCP 1080**：公网访问 `**https://域名:1080`**。

---

## 三、本仓库文件角色

**首次使用：** 在仓库根目录执行 **`cp .env.example .env`**，并填齐 **`.env.example`** 中每一项（**`hub-common.sh` 不再内置默认值**）。也可不用文件，在运行脚本前于 shell 中 **`export`** 相同变量。

| 文件                        | 作用                                                                                                                                                                                                                |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `serve.py`                | 在本机提供 Hello World（纯 HTTP）；端口 `**PORT**`（默认 8080），可选 `**HELLO_TITLE**` 区分多实例                                                                                                                                       |
| `hub-tunnel.sh`               | 反向隧道：无参数 → **10080**→本机；`**--port 端口 应用名`** → Hub 该应用对应 EC2 回环端口                                                                                                                                                  |
| `hub-common.sh`           | 先加载项目根目录 **`.env`**（若存在），再设默认 **`SSH_*`** / **`HUB_*`**；并提供共用函数（`**hub_remote_port**`、`**hub_ssh_host**`、隧道检测/注销 kill、`**hub_background_log**` 等） |
| `hub-register.sh`       | 在 EC2 注册 **`应用名.根域:1080`** 子域站点；**同名已存在则失败退出码 2** 且不改动配置；`**--force`** 可覆盖                                                                                                                                                |
| `hub-unregister.sh`     | 移除 EC2 上该应用路由，并**结束本机**对应 `**ssh -R`**（`**./hub-unregister.sh 应用名**`）；可选 `**--no-kill**` 只删配置                                                                                                                   |
| `hub-status.sh`           | 查询本机 SSH 隧道、EC2 回环监听、已注册 Caddy 路由（`**./hub-status.sh**`）                                                                                                                                                          |
| `hub-applist.sh`          | 仅列出 EC2 上已注册的 **应用名**（`**hub-routes/*.caddy`**，不含 `**_keep**`）：`**./hub-applist.sh**`                                                                                                                             |
| `Caddyfile.ec2.example`   | EC2 主配置：`import hub-routes` + 根站 **10080**                                                                                                                                                                        |
| `hub-ssh.sh`        | 交互登录 EC2（读取 **`.env`**）                                                                                                                                                                |
| `.env.example`            | 远端 / SSH / 公网 URL 等变量模板；复制为 **`.env`**（**`.gitignore`** 已忽略 **`.env`**）                                                                                                                                       |


`**serve.py` 环境变量（可选）：**


| 变量            | 默认             | 说明                       |
| ------------- | -------------- | ------------------------ |
| `PORT`        | `8080`         | 监听端口                     |
| `HOST`        | `127.0.0.1`    | 绑定地址                     |
| `HELLO_TITLE` | `Hello, World` | 页面 `<h1>` 文案（已做 HTML 转义） |


**远端与 SSH（推荐写入 `.env`，见 `.env.example`）：**


| 变量               | 默认                        | 说明                                      |
| ---------------- | ------------------------- | --------------------------------------- |
| `SSH_KEY`        | （必填，无默认） | SSH 私钥 |
| `SSH_TARGET`     | （必填） | SSH 登录目标 |
| `SSH_PORT`       | （必填） | SSH 端口 |
| `HUB_DIR`        | （必填） | EC2 上 Hub 片段目录 |
| `MAIN_CFG`       | （必填） | EC2 上 Caddy 主配置 |
| `HUB_PUBLIC_URL` | （必填） | 脚本提示用公网 HTTPS 前缀（须与实际一致） |
| `REMOTE_PORT`    | （Hub 按名计算 / 根站 10080）     | 覆盖 EC2 侧回环端口；改后须与 Caddy 片段一致              |
| `REMOTE_BIND`    | `127.0.0.1`               | 反向绑定地址；直连 HTTP 见第八节                     |


给脚本执行权限（只需一次）：

```bash
chmod +x serve.py hub-tunnel.sh hub-register.sh hub-unregister.sh hub-status.sh hub-applist.sh hub-ssh.sh
```

---

## 四、EC2 上：OpenSSH（仅「直连 HTTP 到 1080」时需要）

> **若你采用下文「Caddy + 10080 隧道」方案，SSH 反向端口绑定在 127.0.0.1，一般**不必**改 `GatewayPorts`。  
> 只有当你用 `**REMOTE_BIND=0.0.0.0` + `REMOTE_PORT=1080`** 让浏览器直接访问 **HTTP** `http://公网IP:1080`、且不经 Caddy 时，才需要在服务器上放开远程端口绑定。

在 EC2 上编辑 `**/etc/ssh/sshd_config`**，增加或改为：

```text
GatewayPorts clientspecified
```

（或 `GatewayPorts yes`，安全性略差。）

检查配置并重启 SSH：

```bash
sudo sshd -t
sudo systemctl restart ssh
# 部分 AMI 使用 sshd 服务名：
# sudo systemctl restart sshd
```

---

## 五、EC2 上：安装并配置 Caddy（HTTPS :1080）

### 5.1 安装 Caddy（Ubuntu 示例）

按 [Caddy 官方文档](https://caddyserver.com/docs/install) 添加源后安装；若已安装可跳过。

### 5.2 写入 Caddyfile（推荐：Hub + 根站）

将 `**/etc/caddy/Caddyfile**` 配成与仓库 `**Caddyfile.ec2.example**` 一致（域名改成你的）：

```caddy
db.xception.tech:1080 {
	handle {
		reverse_proxy 127.0.0.1:10080
	}
}

import /etc/caddy/hub-routes/*.caddy
```

说明：

- `**db.xception.tech:1080**`：根站 HTTPS；浏览器访问 `**https://db.xception.tech:1080/**`。
- `**import .../hub-routes/*.caddy**`：须写在**站点块外面**（顶层）。每个应用由 `**hub-register.sh**` 生成**独立站点块**（如 `**CoolApp.db.xception.tech:1080**`）；目录内需至少有一个匹配文件（脚本会创建 `**_keep.caddy**` 占位）。
- `**handle { ... 10080 }**`：根路径走默认 SSH 隧道（本机 `**./hub-tunnel.sh**` 无应用名）。

**仅根站、不要 Hub 时**可删 `**import**` 行及 `**hub-routes**` 目录引用；加新应用前再改回 Hub 布局（与仓库 `**Caddyfile.ec2.example**` 一致）。

### 5.3 校验并重载

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

首次启动后，Caddy 会自动向 Let’s Encrypt 申请证书；需保证 **DNS 已指向本机**，且安全组放行 **80 / 1080**（具体挑战方式以日志为准）。

### 5.4 释放 1080 端口

若之前用 `**ssh -R 0.0.0.0:1080:...`** 占用了 **1080**，必须先**结束该 SSH 会话**，再启动 Caddy，否则 Caddy 无法监听 **1080**。

---

## 六、本机：启动网站与隧道

### 6.1 根站（`https://域名:1080/`）

**终端 A** — Hello World（默认 **8080**）：

```bash
cd /path/to/Helloworld_web
python3 serve.py
# 可选：export HELLO_TITLE='我的根站标题'
```

**终端 B** — 根站隧道（EC2 **10080** → 本机 **8080**）：

```bash
cd /path/to/Helloworld_web
export SSH_KEY=/你的路径/私钥   # 若与脚本默认不同
export SSH_TARGET=ubuntu@你的域名   # 若与默认不同
./hub-tunnel.sh
```

### 6.2 再加一个 Hello（Hub 子路径示例）

第二个实例用**不同本机端口**（例如 **9080**），并**先注册**再开隧道：

```bash
# 本机一次性：在 EC2 写入 /etc/caddy/hub-routes/Hello2.caddy
./hub-register.sh Hello2

# 终端 C — 第二个 serve.py
HELLO_TITLE='Hello, World (#2)' PORT=9080 python3 serve.py

# 终端 D — 该应用的隧道（脚本会打印 EC2 回环端口，应与 hub-register 一致）
./hub-tunnel.sh --port 9080 Hello2
```

`--port` 与 `**Hello2**` 顺序可互换：`./hub-tunnel.sh Hello2 --port 9080`。

**请保持每个隧道终端常开**；本机休眠或断网会导致外网访问中断。

---

## 七、验证

1. **EC2 上（可选）** — 根站隧道：
  ```bash
   curl -sS http://127.0.0.1:10080/ | head
  ```
2. **EC2 上（可选）** — 某 Hub 应用（端口以 `hub-register.sh` 输出为准，示例 **22007** 对应 **Hello2**）：
  ```bash
   curl -sS http://127.0.0.1:22007/ | head
  ```
3. **公网 HTTPS**（将 **db.xception.tech** 换成你的根域；**Hello2** 子域须已在 DNS 指向 EC2）：
  ```bash
   curl -sS https://db.xception.tech:1080/ | head
   curl -sS https://Hello2.db.xception.tech:1080/ | head
  ```
   根站与各 **子域应用** 均应为 **200** 且返回预期 HTML。

---

## 八、可选方案：不要 Caddy，只用 HTTP 直连 1080

若暂时不需要 HTTPS，可让 SSH 直接在公网监听 **1080**（需 `**GatewayPorts`**，见第四节）：

```bash
REMOTE_BIND=0.0.0.0 REMOTE_PORT=1080 ./hub-tunnel.sh
```

浏览器访问 `**http://公网IP或域名:1080**`。  
**注意：此模式与「Caddy 占用 1080」不能同时存在。**

---

## 九、常见问题

**1. `remote port forwarding failed`（绑定 0.0.0.0 时）**  
检查 `**GatewayPorts`** 是否已配置并重启 `sshd`。

**2. Caddy 起不来 / 1080 被占用**  
用 `sudo ss -tlnp | grep 1080` 查看；结束占用 **1080** 的旧 SSH `-R` 或其它进程。

**3. Let’s Encrypt 失败**  
确认域名 **A 记录**指向当前 EC2 公网 IP，安全组放行 **80**、**1080**，并查看：

```bash
sudo journalctl -u caddy -n 80 --no-pager
```

**4. 浏览器能开 HTTPS 但内容打不开**  
确认本机 `**serve.py`** 与对应 `**./hub-tunnel.sh**` 均在运行；根站查 `**10080**`，Hub 应用查该应用在 `**hub-register.sh**` 里对应的回环端口。

**5. Hub 子域 404 / 证书错误**  
确认 DNS：`**应用名.根域**` 指向 EC2。先执行 `**./hub-register.sh 应用名`** 并成功 `**reload**` Caddy，再 `**./hub-tunnel.sh --port … 应用名**`；主 `**Caddyfile**` 须为「根站点块 + **顶层** `**import /etc/caddy/hub-routes/*.caddy**`」（见 `**Caddyfile.ec2.example**`）。

**6. 私钥权限**  
SSH 要求私钥不宜过宽，例如：

```bash
chmod 600 /你的路径/私钥
```

---

## 十、多应用 Hub（`https://应用名.域名:1080/`）

> **与第六节的关系**：第六节给出「根站 + Hello2」的**逐步命令**；本节归纳 **Hub 规则**与 **Caddy 要点**，便于查阅。

把 EC2 当成入口：**每个本地 Web 服务**一条 SSH 反向隧道，Caddy 按 **子域（Host）** 转发到不同 EC2 回环端口。`**HUB_PUBLIC_URL**` 的**主机名**为根域（如 **db.xception.tech**），应用 URL 为 `**https://<应用名>.<该主机名>:端口/**`。

### 10.1 流量关系

```
浏览器  https://CoolApp.db.xception.tech:1080/...
              → Caddy（TLS，按站点名选证书与反代）
              → 127.0.0.1:<该应用专用端口>
              → SSH -R（你的电脑 local :3422）
```

- **根路径** `https://db.xception.tech:1080/` 仍可对默认隧道 `**127.0.0.1:10080`**（本机 `**./hub-tunnel.sh**` 不加应用名）。
- 每个 **应用名**（如 `CoolApp`、`Hello2`）对应 **稳定** 的 EC2 回环端口：`20000 + (zlib.adler32(应用名字节) mod 10000)`，落在 **20000–29999**。本地可用 `**python3 -c "import zlib; n=b'Hello2'; print(20000+zlib.adler32(n)%10000)"`** 预览。若两名称冲突，对其中一个设置 `**REMOTE_PORT**` 并 **手动** 修改 EC2 上对应 `**hub-routes/应用名.caddy`** 中的 `**reverse_proxy**` 端口后 `**caddy reload**`。

### 10.2 EC2：主 Caddyfile（根站 + 顶层 import）

将主配置改为与仓库 `**Caddyfile.ec2.example**` 一致：**根站点块内只有默认反代**；`**import hub-routes**` 在**块外**（每个应用片段自带 `**应用名.根域:1080 { ... }**`）：

```caddy
db.xception.tech:1080 {
	handle {
		reverse_proxy 127.0.0.1:10080
	}
}

import /etc/caddy/hub-routes/*.caddy
```

首次对某应用执行 `**./hub-register.sh 应用名**` 时，会在服务器创建 `**/etc/caddy/hub-routes/**` 及占位 `**_keep.caddy**`（若尚不存在），避免 `**import *.caddy**` 无匹配。

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### 10.3 每个新应用：注册路由（本机，一次性）

应用名只能包含 **字母、数字、下划线、连字符**，且不能以连字符开头（用作 DNS 标签时请符合常见主机名规则）。

```bash
./hub-register.sh CoolApp
```

若 EC2 上 **已存在** `**/etc/caddy/hub-routes/<应用名>.caddy`**（同名路由），脚本 **立即退出**（退出码 **2**），**不会** 改写 Caddy、**不会** `reload`、**不会** 动本机或远端任何 **SSH** 连线。  
若要**强制覆盖**已有片段（仍不中断 SSH），使用 `**./hub-register.sh --force 应用名`**。  
否则须先在服务器上 **删除** 对应 `**.caddy`** 文件后再注册。  
**远端需要** 对 `**tee` / `caddy` / `systemctl`** 具备 **免密 sudo**；否则请把脚本打印的片段 **手动** 贴到服务器并重载 Caddy。

### 10.4 本机：按端口拉起隧道（长期运行）

本地服务监听例如 **3422** 时：

```bash
./hub-tunnel.sh --port 3422 CoolApp
```

或：

```bash
./hub-tunnel.sh CoolApp --port 3422
```

保持该终端不断开；每个应用各开一个终端（或日后可改为单条 SSH 多个 `**-R**`，需自行改脚本）。

### 10.5 浏览器访问

- `**https://CoolApp.db.xception.tech:1080/**`、`**https://Hello2.db.xception.tech:1080/**` 等（子域模式下上游收到的路径以 `**/**` 为根，一般**无需**再配 base path）。

### 10.6 前端 / 资源路径说明

子域部署时 Caddy **不再**剥路径前缀，应用可按**站点根路径**提供静态资源（与直接访问本机 `**http://127.0.0.1:端口/**` 行为一致）。

### 10.7 移除某个 App（删 EC2 路由 + 结束本机隧道）

在**跑过 `hub-tunnel.sh` 的那台电脑**上、项目目录执行：

```bash
./hub-unregister.sh CoolAPP
```

会做三件事：

1. **本机**：结束指向当前 `**SSH_TARGET`**、且 `**-R 127.0.0.1:<该应用端口>:…**` 的 `**ssh**` 进程（与 `**hub_remote_port(应用名)**` 一致，若注册时改过端口请设相同 `**REMOTE_PORT**`）。
2. **EC2**：删除 `**/etc/caddy/hub-routes/<应用名>.caddy`**。
3. **EC2**：`**caddy validate`** 并 `**reload**`。

原先在前台跑的 `**./hub-tunnel.sh … 应用名**` 会因为子进程 `**ssh` 被 kill** 而**报错退出**（如 connection closed），这是**正常现象**。

只删 Caddy、不杀本机 SSH 时：

```bash
./hub-unregister.sh --no-kill CoolAPP
```

若隧道在**另一台机器**，须在那台执行带 **kill** 的注销，或在那台手动停 `**ssh -N`**；本脚本只能结束**当前这台机器**上的转发。

### 10.8 查询当前 Hub 有哪些隧道 / 路由

仓库里的 `**./hub-status.sh`** 会汇总三块信息（需能 **SSH** 登录 EC2，环境变量与 `**hub-tunnel.sh`** 一致，如 `**SSH_KEY**`、`**SSH_TARGET**`）：

1. **本机**：正在运行的、指向该 EC2 且带 `**-R`** 的 `**ssh -N**` 进程（可看到 **EC2 端口 → 本机端口**）。
2. **EC2**：`**127.0.0.1`** 上正在 **LISTEN** 的 **10080** 与 **20000–29999**（有监听才表示对应隧道当前连着）。
3. **EC2 磁盘**：`**/etc/caddy/hub-routes/*.caddy`** 里已配置的 **应用名 → `reverse_proxy` 端口**（仅表示 Caddy 会转发到该端口，**不等于**隧道一定在线）。

**只列出应用名（App list）**：在本机项目目录执行 `**./hub-applist.sh`**（需 SSH；输出一行一个名字，已排序）。

**手工在 EC2 上查看监听（不跑脚本时）：**

```bash
ss -tlnp | grep 127.0.0.1 | grep -E ':(10080|2[0-9]{4})\b'
ls -la /etc/caddy/hub-routes/
```

**说明**：若多台电脑分别连同一 EC2，每台自己的 `**hub-status.sh`** 只能看到**那台机器上**的 `ssh` 进程；EC2 上的 **LISTEN** 则是**全局**的（后建立的转发若与先有的端口冲突会失败）。

---

## 十一、初学者：本机与 EC2 重启后如何恢复

日常关机、睡眠或 `**reboot`** 之后，**本机上的网站进程和 SSH 隧道不会自动回来**；EC2 上的服务则通常由 **systemd** 自动拉起。按下面做即可恢复访问。

### 11.1 先理解：什么会丢、什么不会丢


| 位置      | 重启后通常…                                                          | 说明                                                                                         |
| ------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **EC2** | `**sshd`**、`**caddy**` 会随系统启动（若 Caddy 已 `**systemctl enable**`） | `**/etc/caddy/Caddyfile**`、`**hub-routes/*.caddy**`、证书都在磁盘上，**一般不用重做 `hub-register.sh`** |
| **本机**  | `**serve.py`、各条 `hub-tunnel.sh`（`ssh -N`）都会消失**                     | 必须在项目目录里**重新执行**启动命令；**顺序：先本地网站，再 SSH 隧道**                                                 |


若 EC2 **公网 IP 变了**（没用弹性 IP）：要到 DNS 把域名的 **A 记录**改成新 IP，否则浏览器打不开。

### 11.2 EC2 重启后（可选自检）

SSH 登录后执行：

```bash
sudo systemctl status caddy --no-pager
sudo ss -tlnp | grep -E ':1080|:80'
```

- **Caddy 为 active**：说明 **HTTPS :1080** 已在听。  
- 若 **failed**：看 `**sudo journalctl -u caddy -n 50`**，再 `**sudo systemctl restart caddy**`。

**只有在你删改过 Caddy 配置、或换了域名/端口时**，才需要重新 `**hub-register.sh`** 或改 `**Caddyfile**`；单纯重启实例**不需要**重新注册路由。

### 11.3 本机重启后（必做：按顺序执行）

**原则：先让本机端口有服务在听，再开隧道**，否则隧道连上后转发会失败或一直转圈。

**一键恢复**：配置好 **`.env`** 后，按下面「手动」步骤重新打开各终端；或用 **`nohup`** / **`launchd`** 等把 `**serve.py**` 与各条 `**./hub-tunnel.sh**` 拉起来。完成后可执行 `**./hub-status.sh**` 自查。

---

仍想**手动**开多个终端时，可按下面操作：

在 `**Helloworld_web`** 目录下（路径按你机器修改），打开**多个终端**，示例与当前文档一致时：

**终端 1 — 根站网站（默认 8080）**

```bash
cd /path/to/Helloworld_web
python3 serve.py
```

**终端 2 — 根站隧道（10080 → 8080）**

```bash
cd /path/to/Helloworld_web
./hub-tunnel.sh
```

**终端 3 — 第二个 Hello（若你用 Hub 的 Hello2）**

```bash
cd /path/to/Helloworld_web
HELLO_TITLE='Hello, World (#2)' PORT=9080 python3 serve.py
```

**终端 4 — Hello2 隧道**

```bash
cd /path/to/Helloworld_web
./hub-tunnel.sh --port 9080 Hello2
```

你每多一个 Hub 应用，就多一对：**一个终端跑本地服务**，**一个终端跑 `./hub-tunnel.sh --port … 应用名`**。  
`**./hub-register.sh**` 只在**第一次**接新应用名时要做；日常恢复**不用**再跑。

### 11.4 恢复是否成功的快速检查

1. 本机：`curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/` 与（若开了 9080）`**http://127.0.0.1:9080/`** 应为 **200**。
2. 浏览器或另一台机器：`https://你的域名:1080/`、`**https://Hello2.你的域名:1080/`** 应为 **200**。

### 11.5 进阶（可选）

- **本机开机自动恢复**：可用 macOS **LaunchAgent**、Linux **systemd user**、或 `**autossh`** 把上述命令做成登录自启（需自己保管密钥、注意安全）。  
- **EC2 公网 IP 固定**：在 AWS 使用**弹性 IP（Elastic IP）** 绑到实例，避免重启或重建后改 DNS。

---

## 十二、清单小结（从零顺序）

1. 创建 EC2（Ubuntu），安全组放行 **22 / 80 / 1080**。
2. 域名 **A 记录** → EC2 公网 IP。
3. （仅「无 Caddy、HTTP 直连 1080」时）配置 `**GatewayPorts`** 并重启 SSH（见第四节、第八节）。
4. EC2 安装 Caddy：主配置采用 `**Caddyfile.ec2.example**`（`**import hub-routes**` + 根站 **10080**），`**caddy validate`** 后 `**reload**`。
5. 确保 **1080** 由 Caddy 监听，不被 `**ssh -R *:1080`** 占用。
6. 本机：`**python3 serve.py**` + `**./hub-tunnel.sh**`（根站 **10080**→**8080**）。
7. 每增加一个 Hub 应用：`**./hub-register.sh 应用名`** 一次 → 本机 `**PORT=… python3 serve.py**`（可选 `**HELLO_TITLE**`）→ `**./hub-tunnel.sh --port … 应用名**` 常开。
8. 用 `**curl**` 或浏览器验证 `**https://域名:1080/**` 与 `**https://应用名.域名:1080/**`（见第七节）。
9. **本机或 EC2 重启后**：按 **第十一节** 恢复，不必重复从零安装。

完成以上步骤后，即得到：**本机一个或多个 Hello World + EC2 反向隧道 + 对外 HTTPS（Caddy Hub）** 的完整链路。