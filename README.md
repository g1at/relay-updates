# Relay updater artifacts

This repository hosts Relay Windows installer artifacts used by electron-updater.

## Windows 命令行安装

在 **Windows PowerShell 5.1 或 PowerShell 7** 中执行：

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1')))
```

脚本会读取本仓库最新正式 Release，下载 Windows x64 安装包，核对文件大小和 GitHub 提供的 SHA-256，再静默安装。完成后从开始菜单打开 Relay。

新安装默认使用当前用户范围；已有安装由安装器沿用原有目录和范围，机器级安装可能请求 UAC 授权。无需先安装 Git、Node.js、Python 或 GitHub CLI。脚本不安装 WSL 或其他外部工具。

### 只下载

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1'))) -DownloadOnly
```

默认保存到 `%LOCALAPPDATA%\Relay\Installers`。已经下载且大小、哈希正确的安装包可以复用；下载中断或校验失败不会执行文件。

### 指定版本、目录或打开安装向导

```powershell
# 指定正式版本
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1'))) -Version 3.0.0

# 仅下载到指定目录
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1'))) -DownloadOnly -DownloadDirectory 'D:\Downloads\Relay'

# 使用可见的安装向导
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1'))) -Interactive
```

也可以先保存脚本、查看内容后再运行：

```powershell
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1' -OutFile '.\relay-install.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\relay-install.ps1' -DownloadOnly
```

去掉最后的 `-DownloadOnly` 即会执行安装。这里的执行策略参数只影响此次 PowerShell 进程，不修改系统的持久策略。

## 升级与异常处理

- 安装前请退出 Relay，包括托盘中的后台实例。脚本会在开始和启动安装器前检查；检测到运行中的 Relay 会停止，不调用进程终止命令。下载期间请勿重新启动 Relay，安装器自身仍可能处理占用进程。
- 升级沿用安装器保留用户数据的行为，不主动卸载或清理会话、设置和项目。
- 同时存在当前用户和机器级安装记录时，脚本拒绝自动处理，请只下载后使用安装向导管理；不自动降级到已安装版本之前的版本。
- 仅安装已公开、非预发布且拥有 SHA-256 元数据的 Windows x64 版本。缺少校验信息的旧 Release 不会绕过校验执行。
- 脚本核对安装器退出码，并检查安装注册信息、`Relay.exe` 版本和 `app.asar`，无法确认结果时会报错，而不会只根据退出码 0 宣布成功。
- 需要能够访问 GitHub API、Raw 内容和 Release 下载服务。GitHub 限流、代理或网络问题会明确报错，稍后可重试。
- SHA-256 用于核对下载内容与 GitHub 上的文件一致，不替代 Windows 代码签名。当前安装包未配置代码签名证书。

## 手动下载与自动更新

- [最新正式版本](https://github.com/g1at/relay-updates/releases/latest)
- [Windows 安装包](https://github.com/g1at/relay-updates/releases/download/v3.0.0/Relay-3.0.0-Setup.exe)（3.0.0；其他版本请进入 Releases 选择）

Release 中的 `latest.yml` 和 `.blockmap` 供 Relay 内置自动更新使用；命令行脚本直接通过 Release 元数据下载并校验安装包。无需为了更新脚本而重新构建安装包。
