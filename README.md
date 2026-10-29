# faw_REA

给宿主机 OpenCode 使用的 REA 纯静态分析工具箱。工具在 Linux Docker 容器中运行，OpenCode 和模型账号留在宿主机。

本项目覆盖本地 APK、EXE、DLL、ELF、SO 以及 REA 内置支持的静态文件分析；不运行目标，不配置动态调试、Frida、设备连接或浏览器。

## 架构

```text
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
                    ├─ /targets ← targets/，只读输入
                    ├─ /work    ↔ workspace/，工作副本
                    └─ /results ↔ results/，导出证据
```

默认不开放网络端口。运行容器使用 network_mode: none，保留容器内部 loopback，供分析引擎使用。镜像构建、拉取和下载测试样本时需要联网。

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

- Windows：已启动 Docker Desktop，使用 WSL2 / Linux containers。
- Linux：可用的 Docker Engine 和 Docker Compose v2。
- 宿主机 OpenCode。
- 首次构建需要访问 Ubuntu、Node.js、npm 和 GitHub 下载源。

Compose 先按 8 GiB 内存上限、4 CPU、Ghidra 2 GiB JVM 堆配置。这是默认资源预算，不是实测最低要求。需要时从 .env 调整。

## Windows 一次配置

```powershell
git clone https://github.com/maximdevere/faw_REA.git
Set-Location faw_REA
.\scripts\bootstrap.ps1
```

脚本会：
1. 检查 Docker 和 Compose。
2. 构建并启动容器。
3. 检查 JADX 可用性，运行原生静态样本的真实 MCP 测试。
4. 为当前目录创建或合并 opencode.json，备份旧配置。
5. 从镜像导出匹配版本的完整 REA skill。
6. 提示重新启动 OpenCode。

如果要把 MCP 和 skill 配置给另一个 OpenCode 项目：

```powershell
.\scripts\bootstrap.ps1 -OpenCodeProject "D:\projects\analysis"
```

如果项目使用 opencode.jsonc，脚本会保留该文件并要求手动合并 config/opencode.example.json，避免破坏注释和其他设置。

已有镜像且不想重新构建时，先在 .env 中设置 REA_IMAGE，再运行：

```powershell
.\scripts\bootstrap.ps1 -Pull
```

GHCR 镜像只有在维护者发布后才存在，不要把示例地址当作已经发布。

## Linux 启动

```bash
git clone https://github.com/maximdevere/faw_REA.git
cd faw_REA
bash scripts/bootstrap.sh
```

Linux 脚本会导出 skill；若已有 OpenCode 配置，则保留原文件并提示合并模板。新项目会直接生成 opencode.json。

Linux 宿主机的 bind mount 目录必须允许容器 UID/GID 1000 读写。不要为解决这个问题把容器改成 privileged。

## 开始分析

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

容器 healthcheck 仅检查工具和挂载目录，不代替真实分析验收。测试报告在 results，重启后仍保留。

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

GitHub Actions 对 main、PR 和版本标签构建镜像，并运行原生 + APK 静态验收。

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
