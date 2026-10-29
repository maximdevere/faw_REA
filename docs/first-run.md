# 从新电脑开始使用

在 Windows PowerShell 运行：

```powershell
git clone https://github.com/maximdevere/faw_REA.git
cd faw_REA
.\setup.ps1
```

这是给所有使用者的公开入口，不依赖开发者机器、账号、API 地址或预设模型。

1. 检查 Docker：使用 Docker Desktop 的 Linux containers，或已运行 Docker Engine 的 WSL2 发行版。
2. 检查 OpenCode：没有安装时，可选择通过 npm 安装锁定版本（需要 Node.js/npm）。已有 OpenCode 会直接使用。
3. 选择自己的模型连接：已有模型、OpenCode 账号登录，或自定义 OpenAI 兼容 API / 本地服务。
4. 构建并启动工具箱，配置 REA MCP 和匹配版本的 skill，检查 `rea connected`，然后启动 OpenCode。

模型会显示完整的 `provider/model`，同名模型的不同渠道可以区分。首次选择后，项目的主模型和辅助模型都会指向该选择；如果明确选择保留已有配置，向导会同时显示已有辅助模型。已禁用的渠道不会被自动启用。

已有模型服务、API 余额和访问权限由使用者自己提供。工具连接通过不代表模型可用、额度充足，也不代表做过实际目标分析。向导本身不会发送模型请求；之后的 OpenCode 对话和工具结果会发给使用者选择的模型服务。

## 自定义 API

选择“添加自己的兼容 API”，输入服务的 Base URL、模型 ID 和自己的 API Key。需要 `/v1` 的服务必须把它包含在 URL 内；本地无认证服务可留空 Key。不兼容 OpenAI 协议的服务使用 OpenCode 的官方登录和 provider 配置。

Key 通过隐藏输入读取，单独保存到 OpenCode 用户数据目录的 `faw-rea-secrets/`。项目 `opencode.json` 只保存 `{file:...}` 引用，不包含 Key 正文；不会把它加入镜像或提交 Git。文件采用当前用户的私有存储目录，仍是明文凭据文件，不是加密凭据库。迁移到另一台电脑时应重新运行向导，用对方自己的账号配置。

账号登录由 OpenCode 自己处理，使用者在自己的终端完成。脚本不包含任何人的账号、密钥、固定 API 域名或个人余额。

## 常用选项

```powershell
# 保持默认 WSL 不变，明确使用某个发行版中的 Docker
.\setup.ps1 -WslDistro Ubuntu

# 复用已有本地镜像，完成配置后退出
.\setup.ps1 -UseLocalImage -NoLaunch

# 完成后打开 OpenCode 网页，绑定本地地址并自动选择端口
.\setup.ps1 -Web

# 明确选择自己已配置的模型，无交互执行
.\setup.ps1 -NonInteractive -Model "my-provider/my-model" -UseLocalImage
```

`my-provider/my-model` 是格式示例，需要替换为 `opencode models` 显示的实际值。无交互方式必须明确传入模型，不会猜测账号或使用开发者配置。

只有别人已经发布了可用镜像，才能设置 `.env` 中的 `REA_IMAGE` 后使用 `-Pull`。当前默认从源码构建。Docker 尚未安装或需要重启时，应先完成 Docker 官方安装流程；脚本不会代替用户接受安装协议、修改系统权限或处理操作系统重启。

Linux 宿主机仍可使用 README 中的 `scripts/bootstrap.sh`，并在该宿主机 OpenCode 中配置自己的账号。本交互向导主要验收 Windows + Docker Desktop / WSL2 路径；没有承诺在所有平台自动安装 Docker。

## 只重新连接工具

容器已启动、OpenCode 也已有模型时：

```powershell
.\scripts\configure-opencode.ps1 -Verify
```

低层接入脚本负责 MCP、skill 和备份；`setup.ps1` 负责首次使用的完整引导。项目 JSONC 会保留并提示手动合并，避免覆盖已有注释。全局 OpenCode 配置不会被复制到仓库。
