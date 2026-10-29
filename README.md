# faw_REA

带本地 Web 工作台的 REA 纯静态分析工具箱，也可由宿主机 OpenCode 接入。上传样本、查看进度、筛选候选线索与下载证据都可在浏览器完成；分析工具在 Linux Docker 容器中运行，OpenCode 和模型账号留在宿主机。

本项目覆盖本地 APK、EXE、DLL、ELF、SO 以及 REA 内置支持的静态文件分析；不运行目标，不配置动态调试、Frida、设备连接或目标浏览器自动化。

## 架构

```text
本地浏览器 → http://127.0.0.1:8787 → Web 工作台 → REA stdio MCP
宿主机 OpenCode
  ├─ REA 匹配版本的工作流 skill
  └─ docker exec -i -w /work rea-toolbox rea mcp
                    │ stdio / MCP
                    ▼
              rea-toolbox 容器
              ├─ REA + Node.js
              ├─ Ghidra + JDK
              ├─ JADX headless JAR
              ├─ Apktool
              └─ file / binutils / rg / jq / 解压工具
                    │
                    ├─ /uploads ↔ uploads/，Web 上传样本
                    ├─ /targets ← targets/，只读输入
                    ├─ /work    ↔ workspace/，工作副本
                    └─ /results ↔ results/，导出证据
```

默认只向宿主机回环地址开放 Web 端口 8787，MCP 仍走 docker exec stdio，不新增对外 MCP 端口。Compose 使用 Docker bridge 网络，容器能够出站联网，不能将其描述为断网沙箱。Web 只调用预定义的静态分析流程，不提供通用 shell 或任意命令接口。镜像构建、拉取和下载测试样本时需要联网。

## 包含的主要工具

| 组件 | 固定版本或来源 |
| --- | --- |
| REA | 6.8.0，npm package-lock.json 固定传递依赖 |
| Node.js | 24.22.1，官方 SHA-256 |
| Ghidra | 12.1.4，官方 Release SHA-256 |
| JADX headless MCP | 0.7.1，REA 固定 SHA-256 |
| Apktool | 3.0.3，官方 Release SHA-256 |
| 完整 OpenJDK | Ubuntu 的 JDK 21 软件包 |
| Python、procps、util-linux | 系统运行和辅助处理 |
| file、binutils、ripgrep、jq | 静态文件及结果处理 |
| unzip、zip、7zip、xz | 解包 |

REA 通过自身适配器驱动 Ghidra/JADX；只需向 OpenCode 注册一个主 MCP。安装辅助 CLI 不等于 REA 自动提供了通用 shell MCP。

本镜像不包含 IDA。后续若增加 IDA 模块，需要 Linux 版安装与授权以及兼容的上游 IDA MCP；Windows 版目录不能直接充当 Linux 引擎。

## 前置条件

- Windows：已启动 Docker Desktop（Linux containers），或在 WSL2 发行版中运行 Docker Engine + Compose v2。
- Linux：可用的 Docker Engine 和 Docker Compose v2。
- 使用 Agent 深入分析时需要宿主机 OpenCode；Web 的固定分析流程不需要模型 API Key。
- 首次构建需要访问 Ubuntu、Node.js、npm 和 GitHub 下载源。

Compose 先按 8 GiB 内存上限、4 CPU、Ghidra 2 GiB JVM 堆配置。这是默认资源预算，不是实测最低要求。需要时从 .env 调整。

## Windows 一次配置

```powershell
git clone https://github.com/maximdevere/faw_REA.git
Set-Location faw_REA
.\scripts\bootstrap.ps1 -VerifyOpenCode
```

脚本会：
1. 自动选择可用的 Docker Desktop / 原生 Docker；不可用时尝试默认 WSL 发行版，或使用显式指定的发行版。
2. 构建并启动容器。
3. 检查 JADX 可用性，运行原生静态样本的真实 MCP 测试。
4. 为当前目录创建或合并 opencode.json，备份旧配置。
5. 从镜像导出匹配版本的完整 REA skill。
6. 使用 -VerifyOpenCode 时，调用真实的 opencode mcp list，确认 rea connected，然后提供 Web 地址和下一步提示。

连接校验不会发送大模型请求。脚本保留现有 model、small_model、provider、disabled_providers、权限及其他 MCP 设置，不会选择模型、写入 API Key 或启用已禁用的模型渠道。账号和模型仍在 OpenCode 中单独配置。只使用 Web 时可以省略 -VerifyOpenCode。

如果要把 MCP 和 skill 配置给另一个 OpenCode 项目：

```powershell
.\scripts\bootstrap.ps1 -OpenCodeProject "D:\projects\analysis"
```

### 只接入 OpenCode

容器已运行时，只需：

```powershell
.\scripts\configure-opencode.ps1 -Verify
```

脚本自动生成正确的 stdio MCP 命令、合并项目配置、备份旧配置和 skill，并从当前镜像导出匹配版本的完整 REA skill。可重复运行；配置备份位于项目 .opencode/rea-backups/。要配置另一个已有项目，追加 -ProjectPath "D:\projects\analysis"。

如果项目使用 opencode.jsonc，脚本会保留该文件并要求手动合并 config/opencode.example.json，避免破坏注释。全局 OpenCode 的 JSON / JSONC 模型配置不会被修改。

### Windows 使用 WSL Docker

可显式指定发行版，Ubuntu 请替换为自己的名称（例如 kali-linux）：

```powershell
.\scripts\bootstrap.ps1 -WslDistro Ubuntu -VerifyOpenCode
# 已启动容器时，仅补接入配置
.\scripts\configure-opencode.ps1 -WslDistro Ubuntu -Verify
```

脚本会将 Docker Compose 和 skill 导出路径转换为 Linux 路径，并为 Windows OpenCode 生成 wsl.exe → docker exec 的命令。先尝试当前 WSL 用户访问 Docker；只有已允许 sudo -n 时才使用它，不会修改用户组或 sudo 权限。需要强制使用 Windows Docker CLI 时指定 -DockerBackend Native。

WSL 方式请保持该发行版和 Docker 服务运行；脚本不安装或修改系统服务，也不创建后台常驻进程。其他电脑仍需先安装并启动 Docker，安装 OpenCode CLI，完成自己的模型账号配置。

已有镜像且不想重新构建时，先在 .env 中设置 REA_IMAGE，再运行：

```powershell
.\scripts\bootstrap.ps1 -Pull -VerifyOpenCode
```

复用本地已有镜像时使用 -UseLocalImage；它与 -Pull 二选一。

GHCR 镜像只有在维护者发布后才存在，不要把示例地址当作已经发布。

## Linux 启动

```bash
git clone https://github.com/maximdevere/faw_REA.git
cd faw_REA
bash scripts/bootstrap.sh
```

Linux 脚本会导出 skill；若已有 OpenCode 配置，则保留原文件并提示合并模板。新项目会直接生成 opencode.json。

Linux 宿主机的 bind mount 目录必须允许容器 UID/GID 1000 读写。不要为解决这个问题把容器改成 privileged。

## Web 工作台

完成启动后，打开 http://127.0.0.1:8787。也可直接构建并启动，不配置 OpenCode：

```bash
docker compose up -d --build --wait
```

1. 点击“先试试演示样本”并开始分析，验证 Ghidra、REA 和证据导出整条链路。
2. 拖入自己的 APK、EXE、SO 等样本，选择分析类型，填写关注关键词。单文件最大 512 MiB。
3. 在“分析记录”查看进度、候选线索、静态调用结果与错误详情，下载包含摘要、结构化结果与 REA 证据的 ZIP。
4. 需要深入代码时，复制追查提示词交给宿主机 OpenCode；“接入 OpenCode”页可复制完整配置。

当前 Web 是固定工作流，没有内置大模型聊天。任务顺序执行，队列最多等待 8 个任务；服务重启时标记中断，不自动重跑。上传保存到 uploads/，结果保存到 results/web/，两者默认均不提交 Git，也不进入镜像构建上下文。手动放入 targets/ 的文件可由 OpenCode 读取，当前不会自动加入 Web 上传列表。

### 检测范围

- 原生程序：Ghidra 字符串关键词搜索，补充前 3 条命中的交叉引用；最多展示 150 条候选。
- Android APK：JADX 包信息和 Manifest、Apktool 解码资源的关键词命中；不等于全量 DEX 代码审计。
- JavaScript / ASAR：REA 的静态应用分析；.NET：静态元数据，需手动选择“.NET 元数据”。
- 文件清单：REA 支持的静态资源清单，适用范围取决于上游解析器；不承诺解密、脱壳或还原所有格式。

关键词默认 api_key、secret、token、password，可按目标修改。候选命中不等于真实凭据或已确认漏洞，未命中也不能证明没有泄露；加密、混淆、代码拼接和未遍历到的内容需要进一步静态分析。不会执行目标或验证凭据有效性。

Web 绑定本地访问，带同源、Host 和 CSRF 检查；它没有多用户鉴权，不要把端口改成公网监听或当作多人 SaaS 服务。需要改端口时将 .env.example 复制为 .env，调整 REA_WEB_PORT。

## 在 OpenCode 开始分析

把样本放入 targets，例如 targets/demo.apk。在 OpenCode 中使用容器路径：

```text
使用 REA 对 /targets/demo.apk 做纯静态分析，查找硬编码的敏感信息候选，
结合资源、方法和引用关系判断用途。给出证据位置，把线索与已确认问题分开，
将需要保留的证据导出到 /results。不要运行或安装目标。
```

EXE/SO/ELF 同样放入 targets，使用 /targets/...。不要把 Windows 盘符路径直接交给容器内 REA。

一个 MCP 连接对应一份 REA 进程和分析状态。新开 docker exec CLI 不共享原连接的内存会话。重连或重启前，导出需要保留的证据。

## 验证

不需要 Docker 的源代码检查：

```powershell
python tests/test_source.py
python tests/test_web.py
```

容器已启动后的原生分析验收：

```powershell
docker exec rea-toolbox python3 /opt/toolbox/smoke-mcp.py --inside --report /results/smoke-mcp.json
```

验收会真实完成 MCP initialize、tools/list、Ghidra 已知字符串搜索、已知函数反编译和证据导出。测试二进制在构建阶段由本仓库 C 源码编译，不会被执行。

完整 APK 验收，需在宿主机有 Python 时执行：

```powershell
python scripts/fetch-artifacts.py --manifest versions.lock.json --output targets --only apidemos
docker exec rea-toolbox python3 /opt/toolbox/smoke-mcp.py --inside --apk /targets/ApiDemos-debug.apk --report /results/smoke-mcp-android.json
```

公开 APK 从 Appium 下载，并按 REA 的固定 SHA-256 校验。只用于静态解析，不安装到设备。完整测试同时覆盖 JADX 的包/方法读取和 Apktool 资源解码。

Web 上传、分析、查询和 ZIP 下载的真实端到端验收：

```powershell
docker exec rea-toolbox python3 /opt/toolbox/smoke-web.py --apk /targets/ApiDemos-debug.apk --report /results/smoke-web.json
```

容器 healthcheck 检查工具、挂载目录和 Web /health，不代替真实分析验收。单元测试使用替身 MCP 检查 HTTP 边界；smoke-mcp.py 与 smoke-web.py 使用真实 REA/Ghidra/JADX/Apktool。测试报告在 results，重启后仍保留。

## 手动接入 OpenCode

将 config/opencode.example.json 中内容合并到项目或用户配置。核心命令：

```json
{
  "mcp": {
    "rea": {
      "type": "local",
      "command": ["docker", "exec", "-i", "-w", "/work", "rea-toolbox", "rea", "mcp"],
      "enabled": true,
      "timeout": 1800000
    }
  }
}
```

不要加 -t，否则可能污染 MCP stdio。OpenCode 必须能在自己的运行环境中找到 docker。

完整模板还禁用了已知的动态、设备和运行时工具。这是客户端工具选择规则，不是额外的容器安全隔离机制。REA skill 要从同一个镜像导出，不能随意混用 main 分支的说明。

## 发布镜像

GitHub Actions 对 main、PR 和版本标签构建镜像，并运行原生 + APK 的 MCP 和 Web 端到端静态验收。

- 普通 push / PR：只构建和测试。
- Actions 手动触发并选择 publish，或推送 vMAJOR.MINOR.PATCH 标签：测试通过后推送 GHCR。
- 镜像名会转为小写，例如 ghcr.io/maximdevere/faw_rea。
- 第一次发布后，维护者根据需要设置 GHCR package 可见性。
- 不在镜像或仓库中放入 OpenCode API Key、私人样本、IDA 授权或分析结果。

运行镜像的文件系统依赖版本和基础镜像 digest 已固定。apt 系统包在构建时解析更新；完整清单保存在 /opt/toolbox/os-packages.txt。因此源码重建并不承诺逐位一致，发布后应使用镜像 digest 锁定实际运行产物。

其他库存信息：
- /opt/toolbox/versions.lock.json
- /opt/toolbox/npm-packages.json

## 维护与排错

```powershell
docker compose logs --tail 100
docker exec rea-toolbox rea doctor --provider ghidra --json
docker exec rea-toolbox rea doctor --provider jadx --json
docker compose down
```

down 不删除持久卷；除非你明确要清理 REA 缓存，否则不要加 -v。

若首次分析超时，要区分 OpenCode 的 MCP 请求时限和 REA/Ghidra 内部时限。
改完容器环境后重新启动，并重新运行真实静态样本测试。不要用一个空的字符串结果代替成功验收。

第三方工具与许可说明见 THIRD_PARTY_NOTICES.md；本仓库包装代码使用 MIT License。
