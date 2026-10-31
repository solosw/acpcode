# 版本与发布

BaoCode 的版本号怎么定、一个版本怎么发出去、发到哪里、已安装的应用怎么拿到它，以及第一次发布前要准备什么。应用这一侧怎么检查、下载、校验、安装，见 [auto-update.md](auto-update.md)。

- 下载与更新：本 fork 的 [GitHub Releases](https://github.com/solosw/baocode/releases)，清单是 Release 附件 `latest.json`
- 上游官网参考：`https://baocode.dev`（Cloudflare Worker 静态资源，`site/`）；与 fork 桌面更新渠道分开
- 构建与发布：GitHub Actions，`.github/workflows/release.yml`
- 工具：`tool/bump_version.dart`、`tool/build_macos.dart`、`tool/build_windows.dart`、`tool/build_remote_server.dart`、`tool/release_manifest.dart`

## 目录

1. [全貌](#1-全貌)
2. [版本号](#2-版本号)
3. [发一个版本](#3-发一个版本)
4. [CI 做了什么](#4-ci-做了什么)
5. [GitHub Release 上有什么](#5-github-release-上有什么)
6. [更新的数据流](#6-更新的数据流)
7. [第一次发布前的准备](#7-第一次发布前的准备)
8. [出了问题](#8-出了问题)
9. [不用 CI，手动发布](#9-不用-ci手动发布)
10. [手机版](#10-手机版)
11. [浏览器扩展](#11-浏览器扩展)

---

## 1. 全貌

```
你的机器                       GitHub
────────                       ──────
tool/bump_version.dart          Actions：release.yml
改版本号、写更新日志             ├ check         核对版本、标签，不比本仓库已发布版本旧
git push / git push 标签 ─────▶ ├ remote        macOS 上编译四个平台的远程服务端
                               ├ remote-linux  Linux 版在 Docker 里运行验证
                               ├ macos         arm64 / x64，签名、公证、启动验证
                               ├ windows       x64 / arm64，各自原生 runner 打包
                               ├ linux         x64 / arm64，打包、安装和启动验证
                               └ publish       清单、安装包和服务端上传 GitHub Release
                                                    ▲
已安装的 BaoCode：每 6 小时读取 releases/latest/download/latest.json ┘
```

本 fork 的桌面 Release 只发布单一 standard edition，各系统架构都保留；此工作流不引入上游 channel edition、`test-*` 分享或 `server-*` 独立发布流程。桌面版不向 R2 或 `dl.baocode.dev` 上传、也不从那里检查更新。网站、手机版和浏览器扩展的上游独立流程说明保留在后文，仅供参考，不代表 fork 桌面发布已启用它们。

## 2. 版本号

**写法**：`主.次.修订+build`，例如 `1.2.0+12`。写在两处，必须一样（`test/update/version_test.dart` 会检查，CI 也会检查）：

- `pubspec.yaml`：`version: 1.2.0+12`
- `lib/update/version.dart`：`const appVersionString = '1.2.0+12';`

**规则**

- `主.次.修订` 是给人看的版本（marketing 版本），按 semver：修 bug 加修订号，加功能加次版本号，不兼容的大改加主版本号。
- `+build` 是给机器比较的序号，**每次发布都加 1，永远不回退**。应用只接受比自己新的版本（先比 `主.次.修订`，再比 build），build 号没涨，用户就收不到。
- **标签**：`v` + marketing 版本，例如 `v1.2.0`。CI 会核对标签和 pubspec.yaml 是否一致。
- **同一个版本可以重新发布**（比如发出去才发现包有问题，修好后把标签挪到新提交上重推，见第 3 节）。GitHub Release 会重建，下载链接末尾带着文件哈希（`?sha256=<前 16 位>`），重新发布后是新的地址。但已经装上这个版本的用户不会再收到它（版本号没变），所以只适合还没人装上、或者问题不影响已装用户的时候；否则发 `1.2.1`。
- **预发布版**（`1.2.0-beta.1`）目前不支持：只有一个更新渠道，所有用户读同一份 `latest.json`，发 beta 就是发给所有人。以后要做的话见 [auto-update.md 第 13 节](auto-update.md#13-已知限制与待办)。

**改版本号用工具**，两处一起改，build 号自动加 1：

```sh
dart run tool/bump_version.dart patch    # 1.2.0+12 → 1.2.1+13
dart run tool/bump_version.dart minor    # 1.2.0+12 → 1.3.0+13
dart run tool/bump_version.dart major    # 1.2.0+12 → 2.0.0+13
dart run tool/bump_version.dart 1.4.0    # 1.2.0+12 → 1.4.0+13
```

**更新日志**：`release-notes/<版本>.en.md` 和 `release-notes/<版本>.zh.md`，是唯一的来源，不另外维护 CHANGELOG.md。它们会出现在：

- `latest.json`：设置 → 更新里显示（纯文本，按应用语言选）
- 网站的更新日志页 `baocode.dev/changelog`、`baocode.dev/zh/changelog`：`tool/build_changelog.dart` 生成 `site/changelog.html`、`site/zh/changelog.html`，跟 notes 一起提交（网站没有构建步骤，Cloudflare 原样发布 `site/`）。更新通知里的「更新日志」按钮直接打开这一页对应版本的位置（`#v1.2.0`）
- GitHub Release 的说明（英文那份）

`bump_version.dart` 会顺手生成草稿（`tool/draft_release_notes.dart`，也可以单独跑）：上一个标签以来的 `feat` / `perf` / `fix` 提交标题，分到「New / Improved / Fixed」（中文「新功能 / 改进 / 修复」）下面，不含 `site`、`ci` 的提交。提交标题是写给开发者的，**草稿要改写成用户看得懂的话**，每版十行左右，中文那份写中文。格式只用普通段落和 `-` 列表：设置页按纯文本显示，标题、加粗之类的 Markdown 符号会原样露出来。

没有 notes 也能发，但 CI 会给出警告：通知里没有「更新日志」按钮，网站上也没有这个版本，GitHub Release 改用自动生成的提交列表。`test/tool/build_changelog_test.dart` 会检查网站页面是不是最新的。

## 3. 发一个版本

以发布 `1.2.0` 为例：

```sh
dart run tool/bump_version.dart minor          # 1.1.3+12 → 1.2.0+13，并生成更新日志草稿
# 改写 release-notes/1.2.0.en.md、release-notes/1.2.0.zh.md
dart run tool/build_changelog.dart             # 生成网站的更新日志页
flutter test test/update/version_test.dart test/tool/build_changelog_test.dart
git add pubspec.yaml lib/update/version.dart release-notes/ site/changelog.html site/zh/changelog.html
git commit -m "chore: release 1.2.0"
git push origin main
git tag v1.2.0
git push origin v1.2.0                          # 从这里开始 CI 接手
```

然后在 GitHub 的 Actions → Release 里看进度（macOS 签名使用 `release` 环境；如果设了审批人，要点一下 Approve）。macOS 公证要等几分钟，整个流程大约 20～30 分钟。

macOS 最常见的失败是钉票据（`stapler staple`）：Apple 的 CloudKit 会连续几分钟断开连接（-1005，stapler 报 Error 68），公证本身是成功的。`build_macos.dart` 遇到这种情况会退避重试，总共约 12 分钟。还不行的话，`release-retry.yml` 会把失败的任务自动重跑一次（只在第一次失败、且失败任务里有 macOS 构建时）。换一台机器通常就能过。再失败就要手动 Re-run。

完成后确认：

- [ ] GitHub Release 的 `latest.json` 是新版本，链接均指向本 fork 的 Release 附件
- [ ] Windows x64 / arm64、macOS arm64 / x64、Linux x64 / arm64 包及四份服务端附件齐全
- [ ] Release 更新日志是这个版本
- [ ] 装着旧版本的机器上点“检查更新”，能发现、下载、重启装上

**重新发布同一个版本**（标签挪到新提交上）：

```sh
git push origin :refs/tags/v1.2.0                # 删掉远端的标签
git tag -f v1.2.0 && git push origin v1.2.0      # 打在现在的提交上，重新推
```

CI 会照常构建，重新建 GitHub Release（不删除触发构建的标签），替换附件。

**只想试一下构建**：Actions → Release → Run workflow。只构建、不发布，产物在这次运行的 Artifacts 里（macOS 包这时是 ad hoc 签名，只能在自己机器上打开）。

**上游官网部署参考（与 fork 桌面更新渠道独立）**：和应用发版无关，推送到 `main` 就由 Cloudflare Workers Builds 部署到 baocode.dev（GitHub 上这个提交的检查里有“Workers Builds: baocode”）。

- 先预览：推送任何别的分支，Workers Builds 只上传一个预览版本、不上线。预览地址是 `https://<版本 ID 前 8 位>-baocode.leokun-cn.workers.dev`，版本 ID 在那个提交的“Workers Builds: baocode”检查详情里。
- 只发官网：把 `site/` 的改动单独提交推到 `main` 即可，`main` 上没发版的应用代码不受影响（应用只在推 `v*` 标签时发布）。

## 4. CI 做了什么

`.github/workflows/release.yml`，推送 `v*` 标签时运行：

| Job | 机器 | 做什么 |
| --- | --- | --- |
| `check` | Ubuntu | pubspec.yaml 和 `version.dart` 一致；版本是 `x.y.z+build`；标签是 `v<x.y.z>` |
| `remote` | macOS 15 | 下载和 Flutter 同版本的 x64 Dart SDK → 编译远程服务端（`--all`：Linux x64/arm64 交叉编译；macOS arm64 用本机的 dart，macOS x64 用 x64 的 dart 经 Rosetta，`dart compile exe` 只能在 Mac 上、按 dart 自己的架构编 macOS 版）→ `tool/test_remote_server_macos.sh`：在这台 Mac 上把两份 macOS 版各跑一遍 → 上传 `remote`（`VERSION`、`servers.json`、`.gz`）和 `remote-linux`（Linux 的两个二进制）两个产物 |
| `remote-linux` | Ubuntu | `tool/test_remote_server.sh`：在 Docker 里的 Ubuntu 20.04 / 24.04、Debian 12、Rocky Linux 8 上，两种架构各跑一遍（arm64 用 QEMU 模拟），要能启动、回答 `initialize`、列出目录 |
| `macos` | macOS 15 | 有证书就导入临时钥匙串 → `tool/build_macos.dart --remote-built`：构建 universal 的 .app，**检查是 universal**（每个可执行文件都有 arm64 和 x86_64）→ 放进 `remote` 任务的 `servers.json` → 用 `ditto --arch` 拆成 Apple silicon（arm64）和 Intel（x64）两个应用，各自检查只剩一种架构，下面每个各做一遍：→ 签名（有证书用 Developer ID，带 hardened runtime；没有就 ad hoc，**不带** hardened runtime，否则系统拒绝加载应用自己的框架、一启动就崩；总要重签，因为放进去的文件要包进签名）→ 做 dmg → 有证书时签 dmg、公证、钉票据 → 打更新用的 zip → **把两个 zip 解开各真正启动一次**（Intel 版经 Rosetta），15 秒内退出就不发 |
| `windows` | Windows（x64 在 `windows-latest`，arm64 在 `windows-11-arm`） | 装 Inno Setup → `tool/build_windows.dart --remote-built --arch <x64\|arm64>`：构建、放进 `servers.json`、打安装包。Flutter 只能给本机架构构建，所以 arm64 在 Arm 机器上编；Flutter 的 Windows 压缩包里是 x64 的 Dart，arm64 改为按标签 clone Flutter。fork 两种架构都保留 Flutter 自带的引擎，不恢复旧补丁引擎；OpenSSH 用 `OpenSSH-ARM64.zip`。安装包 `BaoCode-<版本>-setup-arm64.exe`，和 x64 同一个 AppId，互相覆盖安装 |
| `linux` | Ubuntu 22.04（x64 / arm64 各一台） | 构建、打 `.deb` 和 tarball → 安装并启动验证 → 上传产物 |
| `publish` | Ubuntu | 汇总所有架构的安装包、macOS 更新 zip 和四个 `baocode-server-*.gz` → 写 `latest.json` → 建 GitHub Release 并上传全部附件（重新发布时先删旧 Release，不删标签） |

几个设计上的考虑：

- **远程服务端和安装包一起上传**：`remote` 任务编译一次，macOS 和 Windows 两个应用带同一份 `servers.json`。四个 `baocode-server-*.gz` 作为 GitHub Release 附件，地址是 `https://github.com/solosw/baocode/releases/download/v<营销版本>/baocode-server-<平台>.gz`。重新发布同一个标签会替换这些文件。
- **下载失败可以手动安装**：见 [ssh-remote.md 第 9.3 节](ssh-remote.md)。
- **`downloads`**：给下载页面的条目是 `macos-arm64`、`macos-x64`、`windows`（兼容原 x64 键）、`windows-arm64`、`linux-x64`、`linux-arm64`。应用更新键则是 `windows-x64` / `windows-arm64`；x64 版即使在 Arm 上模拟运行也继续更新到 x64，不自动换架构。
- Flutter 版本固定在工作流的 `FLUTTER_VERSION`，升级 Flutter 时一起改。

## 5. GitHub Release 上有什么

`https://github.com/solosw/baocode/releases/download/v<营销版本>/` 下的附件：

```
latest.json                              应用读取的版本、更新日志、下载地址和校验值
BaoCode-1.2.0-setup.exe                   Windows x64：首次安装和自动更新
BaoCode-1.2.0-setup-arm64.exe             Windows on Arm：同上
BaoCode-1.2.0-mac-arm64.zip               macOS Apple silicon：自动更新
BaoCode-1.2.0-mac-x64.zip                 macOS Intel：自动更新
BaoCode-1.2.0-arm64.dmg                   macOS Apple silicon：首次安装
BaoCode-1.2.0-x64.dmg                     macOS Intel：首次安装
BaoCode-1.2.0-linux-amd64.deb             Linux x64：安装和更新
BaoCode-1.2.0-linux-arm64.deb             Linux arm64：安装和更新
BaoCode-1.2.0-linux-amd64.tar.gz          Linux x64：手动解包
BaoCode-1.2.0-linux-arm64.tar.gz          Linux arm64：手动解包
baocode-server-linux-x64.gz              SSH 远程服务端，连接时按需下载
baocode-server-linux-arm64.gz
baocode-server-darwin-x64.gz
baocode-server-darwin-arm64.gz
```

旧版本 Release 的服务端附件要保留，旧版应用的 `servers.json` 仍指向它们。最新版入口是 `https://github.com/solosw/baocode/releases/latest/download/latest.json`。清单格式见 [auto-update.md 第 5 节](auto-update.md#5-服务端约定)，其中上游 R2 部署说明不用于 fork。

## 6. 更新的数据流

**发布时**（CI 的 `publish`）：

1. 对每个平台的安装包算 SHA-256；签名私钥可选，只有 `BAOCODE_UPDATE_SIGNING_KEY` 与应用公钥匹配时才生成 Ed25519 签名。fork 不要求更新签名。
2. 写出 `latest.json`：版本、日期、更新日志、每个平台的 `url / size / sha256`（有匹配私钥时另带 `signature`）。
3. 将安装包、服务端和 `latest.json` 一起上传到对应标签的 GitHub Release。

**已安装的应用**（`update.mode` 是默认的“自动检查并下载”时）：

1. 启动 30 秒后、之后每 6 小时，GET `https://github.com/solosw/baocode/releases/latest/download/latest.json`。
2. 解析清单；下载链接必须通过 `UpdateUrlPolicy`（包括 GitHub Release 下载域名）；本 fork 清单生成 GitHub 附件链接。版本不比自己新，或者没有本平台的条目 → 已是最新，结束。
3. 后台下载本平台的安装包（Mac 按处理器取 Apple silicon 或 Intel 的包，见 [auto-update.md 5.2](auto-update.md#52-latestjson-格式)）到 `<数据目录>/updates/<版本>/`，支持断点续传。
4. 校验大小和 SHA-256；若清单带签名也校验 Ed25519（公钥内置在应用里），无签名可用。任何适用的校验不过就删掉，报错。macOS 还会检查新 .app 的 bundle id，以及在当前应用有正式签名时，新 .app 是不是同一个 Team 签的。
5. 主窗口右下角弹通知。用户点“立即重启更新”后，走和平时退出一样的确认（未保存的文件、运行中的 agent 和终端），确认了才安装：
   - Windows：应用退出后，带 `/SILENT /RELAUNCH` 运行新的 setup.exe，覆盖安装到原来的位置，再重新打开。
   - macOS：解压出新 .app，等应用退出后由脚本替换原来的 BaoCode.app，再打开。
   - Linux：已安装的 deb 版本用 `pkexec dpkg -i` 安装对应架构的 `.deb`，授权成功后等应用退出再重启；手动解包或没有 pkexec 时提示手动更新。
6. 新版本启动时清理 `updates/` 里旧版本的下载。

设置和对话放在数据目录里，不在安装目录里，更新不会动它们。

**上游官网参考（不是 fork 的桌面更新渠道）**（首页和 `baocode.dev/download`，`site/site.js`）：浏览器读同一份 `latest.json`，按其中的 `downloads` 换上版本号、两个 dmg 和 Windows 安装包的链接（带哈希）和大小。下载页的 macOS 卡片有 Apple silicon 和 Intel 两个按钮，默认突出 Apple silicon；Chromium 系浏览器能报出处理器架构，Intel Mac 上会改为突出 Intel（`site/download.js`）。需要 R2 的 CORS 允许 `https://baocode.dev`（见 7.1）。读不到时显示页面里写死的版本；页面里的下载链接本身写的是 `/dl/windows`、`/dl/windows-arm64`、`/dl/macos-arm64`、`/dl/macos-x64`（Arm64 的按钮先隐藏，`site.js` 读到清单里有 `windows-arm64` 才显示），由 Worker（`site-worker/index.js`，只接管 `/dl/*`）按当时的 `latest.json` 302 到对应安装包，所以脚本没跑完、被拦或页面被缓存时下到的也是最新版，发版不用改页面里的链接。

**两把“钥匙”管的是不同的事**：

| | 防的是什么 | 没有它会怎样 |
| --- | --- | --- |
| 更新签名私钥（Ed25519，可选） | 在 SHA-256 之外验证发布者身份 | fork 可生成无签名清单；密钥保管见 [auto-update.md 6.3](auto-update.md#63-保管) |
| Apple Developer ID + 公证 | macOS 的 Gatekeeper 拦截从网上下载的未知应用 | 用户第一次打开 dmg 里的应用时被拦：“已损坏，无法打开” |
| Windows 代码签名（还没做） | SmartScreen 的“未知发布者”警告 | 第一次安装时多点一次“仍要运行” |

fork 的更新私钥可选；macOS 的同 Team 校验仍保留。应用自己下载的文件不带隔离属性，不经过 Gatekeeper 和 SmartScreen。

## 7. 第一次发布前的准备

全部是一次性的。**这些值都直接填进 GitHub 或 Cloudflare 的后台，不要发到聊天里，也不要提交到仓库。**

### 7.1 Cloudflare（上游网站、移动版与扩展参考）

以下是上游的部署配置，不是 fork 桌面发布的前置要求。fork 的 `release.yml` 不使用这些 R2 secrets 或域名。

1. **R2 存储桶**：R2 → Create bucket，名字比如 `baocode-downloads`。
2. **自定义域名**：存储桶 → Settings → Custom Domains → Connect Domain → `dl.baocode.dev`。不要开 `r2.dev` 公共地址。
3. **CORS**（给下载页读 `latest.json`）：存储桶 → Settings → CORS Policy：
   ```json
   [
     {
       "AllowedOrigins": ["https://baocode.dev"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["*"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
4. **API 令牌**：R2 → Manage R2 API Tokens → Create API token，权限 **Object Read & Write**，范围**只选这个存储桶**。记下 Access Key ID 和 Secret Access Key（只显示一次），以及页面上的 Account ID。
5. **网站**：Worker `baocode`，静态资源是 `site/`（`_headers`、`_redirects` 照常生效），Settings → Builds 连着 GitHub 仓库（生产分支 `main`），自定义域名 `baocode.dev`。

### 7.2 GitHub

1. **环境**：Settings → Environments → New environment，名字 `release`。
   - Deployment branches and tags → Selected branches and tags → 加一条 **Tag**，规则 `v*`。只有 `v*` 标签触发的运行能用这个环境里的密钥。
   - 可选：Required reviewers 加上你自己。每次发布要你在 Actions 里点一下批准，多一道保险。
2. **环境密钥**（`release` 环境 → Environment secrets）：只需配置下面 7.3 的六个 Apple 签名/公证值（没有时走 ad hoc）。桌面发布不需要 R2 凭据或 `UPDATE_SIGNING_KEY`。
3. **工作流权限**：`publish` job 用 `contents: write` 上传 Release，`release-retry.yml` 用 `actions: write` 重跑失败任务；均使用仓库自己的 `github.token`。
4. **保护标签**：Settings → Rules → Rulesets → New tag ruleset，目标 `v*`，限制创建、更新、删除，只允许你自己绕过。这样只有你能发版。

本机如需可选的更新签名，私钥与离线备份仍要保管好（见 [auto-update.md 6.3](auto-update.md#63-保管)）。

### 7.3 Apple（macOS 签名与公证）

**需要 Apple 开发者账号吗？** 要。没有的话应用照样能构建、能自动更新，但新用户第一次从网上下载打开时会被 Gatekeeper 拦下（“BaoCode 已损坏，无法打开”），只能在终端里运行 `xattr -dr com.apple.quarantine` 才能打开。对外发布基本绕不过去。

1. **加入 Apple Developer Program**（每年 99 美元）：<https://developer.apple.com/programs/enroll/>
   - 我们**以个人身份**加入：用本人的 Apple ID（要开双重认证）。中国大陆的表单要求填身份证上的中文姓名和身份证号。在 iPhone 或 Mac 的 Apple Developer App 里注册最快，要拍证件做身份验证；也可以在网页上注册。付款后一般一两天内通过。
   - 证书上显示的是个人姓名（`Developer ID Application: <姓名> (<Team ID>)`），用户在签名信息里能看到，双击打开时的提示里看不到。
   - 以后想改成组织：可以联系 Apple 把个人账号转成组织账号（需要 D-U-N-S 编号）。转换前向 Apple 确认 Team ID 不变，否则见下面的注意。
2. **Developer ID Application 证书**：只有账号持有人（Account Holder）能创建。
   - 在 Mac 上打开 Xcode → Settings → Accounts → 登录 Apple ID → Manage Certificates → 左下角 `+` → **Developer ID Application**。
   - 打开“钥匙串访问” → 登录 → 我的证书 → 找到 “Developer ID Application: <名字> (<Team ID>)” → 右键导出为 `.p12`，设一个密码。
   - 终端运行 `security find-identity -v -p codesigning`，复制那一行开头的 40 位十六进制指纹（也可以用引号里的完整名字，但名字里有中文时用指纹更稳）。
3. **公证用的 API 密钥**：App Store Connect → 用户和访问 → 集成 → App Store Connect API → 团队密钥 → `+`，访问权限选 **Developer**。下载 `.p8` 文件（只能下载一次），记下 Key ID 和页面上方的 Issuer ID。
4. **填进 `release` 环境的密钥**：

   | 名字 | 值 |
   | --- | --- |
   | `MACOS_CERTIFICATE` | `base64 -i 证书.p12 \| pbcopy` 复制出来的内容 |
   | `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 |
   | `MACOS_SIGN_IDENTITY` | 第 2 步复制的指纹，例如 `1A2B3C…`（40 位）；或完整名字 `Developer ID Application: <姓名> (<Team ID>)` |
   | `NOTARY_KEY` | `.p8` 文件的全部内容（包括 `-----BEGIN PRIVATE KEY-----` 那两行） |
   | `NOTARY_KEY_ID` | Key ID |
   | `NOTARY_ISSUER` | Issuer ID |

5. 先用 Actions → Release → Run workflow 试一次：手动运行拿不到密钥，所以这一步只验证构建本身。要验证签名和公证，就发一个真实版本，或者在本机按第 9 节手动跑 `tool/build_macos.dart`。

**注意**

- **Team 一旦用上就别换**：应用正式签名之后，只接受同一个 Team 签名的更新（`lib/update/installer_io.dart`）。从 ad hoc 签名的版本（现在的 1.0.0）更新到第一个正式签名的版本没问题；之后换 Team（比如另注册一个组织账号），老用户就得手动重装一次。
- **证书有效期 5 年**：到期前在同一个 Team 下新建一张，换掉 `MACOS_CERTIFICATE` 等密钥即可，Team 不变，老用户不受影响。已经公证过的版本过期后仍然能打开。
- **不需要提供给我**：证书、密码、密钥都只填在 GitHub 里。脚本和工作流已经按上面这些名字写好了，填好就能用。

## 8. 出了问题

| 情况 | 怎么办 |
| --- | --- |
| `check` 失败：版本不一致 / 标签不对 | 按报错改，删掉远端标签（`git push origin :refs/tags/v1.2.0`），重新打标签推送 |
| `check` 失败：比已发布的旧 | `tool/bump_version.dart` 加到比已发布的新 |
| `remote-linux` 失败：Docker 里跑不起来 | 日志里有每个系统、每种架构的结果和服务端的输出。在本机用 `dart run tool/build_remote_server.dart && tool/test_remote_server.sh` 复现（需要 Docker） |
| `remote` 失败：macOS 版没编出来或跑不起来 | 多半是下载 x64 Dart SDK 失败（Flutter 带的 Dart 版本在 dart-archive 上没有对应的包），或 Rosetta 没装上。在 Apple silicon 的 Mac 上用 `dart run tool/build_remote_server.dart --all --macos-x64-dart <x64 sdk>/bin/dart && tool/test_remote_server_macos.sh` 复现 |
| `macos` 失败：Not universal | 某个框架只编了一种架构，日志里列出了是哪个。拆出来的某个包会少这个框架的代码，在用到它时崩溃，所以不发 |
| `macos` 公证失败 | 日志里有 Apple 返回的详细原因（哪个文件、什么问题）。常见原因：某个二进制没开 hardened runtime、没有时间戳 |
| `publish` 上传失败 | Release 附件可能不完整（重新发布时旧 Release 已删除）。检查日志和附件，修好后按第 3 节重新发布同一个版本 |
| 发出去的版本有问题 | 尽快发一个修复版（版本号更高）。也可以把上一版的 `latest.json` 传回去，让还没更新的人停在旧版，但已经更新的人不会被降级。见 [auto-update.md 5.5](auto-update.md#55-撤回一个版本) |
| 用户报“检查更新失败” | 见 [auto-update.md 第 10 节](auto-update.md#10-故障排查) |

## 9. 不用 CI，手动发布

CI 不可用时的备用办法，步骤和 CI 一样：

```sh
# macOS 上：先把四份远程服务端都编好（x64 的 Dart SDK 见 docs/ssh-remote.md 9.1）
dart run tool/build_remote_server.dart --all --macos-x64-dart <x64 sdk>/bin/dart
# 然后打包（有证书的话先设好第 7.3 节对应的环境变量，见 tool/build_macos.dart 开头）
dart run tool/build_macos.dart --remote-built
# Windows x64 / arm64 各自的机器上：拷入同一份 Mac 的 build/remote/
dart run tool/build_windows.dart --remote-built --arch x64
# 在 Windows Arm 机器上改为 --arch arm64（Flutter 不做 Windows 跨架构构建）
# Linux x64 / arm64 机器上：flutter build linux --release && sh tool/package_linux_deb.sh

# 所有架构的包拷到同一台机器之后（私钥可选）
dart run tool/release_manifest.dart \
    --version 1.2.0+13 \
    --windows build/installers/BaoCode-1.2.0-setup.exe \
    --windows-arm64 build/installers/BaoCode-1.2.0-setup-arm64.exe \
    --linux-x64 build/installers/BaoCode-1.2.0-linux-amd64.deb \
    --linux-arm64 build/installers/BaoCode-1.2.0-linux-arm64.deb \
    --macos-arm64 build/installers/BaoCode-1.2.0-mac-arm64.zip \
    --macos-x64   build/installers/BaoCode-1.2.0-mac-x64.zip \
    --dmg-arm64   build/installers/BaoCode-1.2.0-arm64.dmg \
    --dmg-x64     build/installers/BaoCode-1.2.0-x64.dmg \
    --notes-en release-notes/1.2.0.en.md --notes-zh release-notes/1.2.0.zh.md
```

然后在对应标签的 GitHub Release 上传全部安装包、更新 zip、四个 `baocode-server-*.gz` 和 `build/installers/latest.json`，与 CI 的附件列表一致。`servers.json` 指向同一个营销版本的标签；不要只更新清单而漏传安装包或服务端。旧版本的服务端附件要保留。

macOS 本机签名时用的环境变量：

| 变量 | 值 |
| --- | --- |
| `BAOCODE_MACOS_SIGN_IDENTITY` | 证书的 40 位指纹，或 `Developer ID Application: <名字> (<Team ID>)`；证书在钥匙串里 |
| `BAOCODE_NOTARY_KEY` | `.p8` 文件的路径 |
| `BAOCODE_NOTARY_KEY_ID` | Key ID |
| `BAOCODE_NOTARY_ISSUER` | Issuer ID |

只设 `BAOCODE_MACOS_SIGN_IDENTITY` 就只签名、不公证；都不设就是 ad hoc 签名。

## 10. 手机版

> 以下保留上游独立流程的说明；不由 fork 桌面 Release 工作流启用，也不改变 fork 的 GitHub 更新渠道。

手机版（Android 的 APK、iOS 走 TestFlight）由 `.github/workflows/mobile.yml` 构建，和桌面版分开发布，版本号也分开（手机版 `pubspec.yaml` 里的版本，`0.x` 算 Beta）。官网下载页的 Android 按钮是 `/dl/android`，由 `site-worker/index.js` 按 `releases/mobile/latest.json` 跳转到当前版本。

```sh
git tag mobile-v0.1.0 && git push origin mobile-v0.1.0      # 发布：标签要和手机版的版本一致
git tag mobile-test-foo && git push origin mobile-test-foo  # 测试包：APK 传到 dl.baocode.dev/test/mobile-…，iOS 照样传 TestFlight
```

CI 从 `baocode-dev/mobile` 的 main 取代码（放在本仓库旁边，`../monad` 的包照常能找到），分两台机器构建：

- **Android**（Ubuntu）：`flutter build apk --release`，用发布密钥签名。每个版本都要用**同一把密钥**，否则装不上旧版之上，只能卸载重装。
- **iOS**（`macos-26`，要 Xcode 26：App Store Connect 只收 iOS 26 SDK 编的包）：导入 Apple Distribution 证书和 App Store 描述文件 → 把工程里 Runner 目标的 Release 配置改成手动签名（工程本身是自动签名，要登录开发者账号，CI 上没有；只改 Runner，Pods 的目标不能带描述文件）→ `flutter build ipa`，build 号用本工作流的 run number（TestFlight 不收重复的 build 号）→ `xcrun altool --upload-app` 用 App Store Connect API Key 上传到 TestFlight。**`mobile-test-*` 也上传**：iOS 的测试员走 TestFlight。上传后苹果要处理几分钟，测试员才看得到。

APK 上传时用 `--content-type` 说明类型（`application/vnd.android.package-archive`）。

发布时 APK 传到 `releases/mobile/<版本>/`，最后写 `releases/mobile/latest.json`（`version`、`pubDate`、`beta`、`downloads.android` 的 `url / size / sha256`）。桌面版的 `latest.json` 不受影响。

iOS 在 App Store Connect 上的 App 是 **BaoCode**（Apple ID `6825371537`，Bundle ID `dev.baocode.mobile`，Team `77SLP2NCVR`）。证书和描述文件一年一换：到期前用 App Store Connect API（或开发者网站）新建 Apple Distribution 证书、用它重做 App Store 描述文件，换掉下面三个密钥。

TestFlight 上每个 build 都要回答出口合规（加密）问题，否则停在「缺少合规证明」；在手机版的 `Info.plist` 里加 `ITSAppUsesNonExemptEncryption` 就不用每次回答。

**`release` 环境里要有的**（7.2 那些之外）：

| 名字 | 是什么 |
| --- | --- |
| `MOBILE_DEPLOY_KEY` | 读 `baocode-dev/mobile` 的部署密钥（私钥）。公钥加在那个仓库的 Settings → Deploy keys，只读即可 |
| `ANDROID_KEYSTORE` | Android 发布密钥库（`.jks`）的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | 它的密码（密钥别名 `baocode`，密钥密码与之相同） |
| `IOS_CERTIFICATE` | Apple Distribution 证书 `.p12` 的 base64 |
| `IOS_CERTIFICATE_PASSWORD` | 它的密码 |
| `IOS_PROFILE` | `dev.baocode.mobile` 的 App Store 描述文件（`.mobileprovision`）的 base64 |

上传 TestFlight 用的是 7.3 公证用的那把 App Store Connect API Key（`NOTARY_KEY`、`NOTARY_KEY_ID`、`NOTARY_ISSUER`），它的职能是 App 管理，两件事都够用。

环境的部署规则里要允许 `mobile-*` 标签。

下载页这两张卡片各带一个二维码（`site/qr/android.svg`、`site/qr/ios.svg`，鼠标悬停或点击卡片时显示）：码里是卡片自己那个按钮的链接，也就是 `/dl/android`、`/dl/ios`，扫到就跳到当时最新的那版安装包。链接变了就先跑 `dart run tool/make_download_qr.dart` 重新生成（`test/tool/download_qr_test.dart` 会检查页面、按钮和码三者一致）。**别把 `dl.baocode.dev` 上带哈希的直链写进码里**：那地址每次发版都换，码是要能一直用的。`latest.json` 里已经没有 iOS 的包：`/dl/ios` 跳到 TestFlight 公开测试的链接（`site-worker/index.js` 的 `TESTFLIGHT`，App Store Connect → BaoCode → TestFlight → Public beta），每个 build 都是这一个，上了 App Store 再换。要暂时下线哪个平台，把它加进 `site-worker/index.js` 的 `MOBILE_OFFLINE`，它的链接就跳回下载页。

> 发布密钥库丢了就再也发不了能覆盖安装的 APK：本机和 CI 之外务必另存一份。

## 11. 浏览器扩展

> 以下为上游独立发布流程参考；不是 fork 桌面工作流的一部分。

浏览器扩展（`browser_extension/`，原理见 `lib/browser/browser_bridge.dart`）由 `.github/workflows/extension.yml` 打包发布，版本号就是 `manifest.json` 里的 `version`，和应用、手机版都分开。用户有两种装法，官网下载页「浏览器扩展」一节两个按钮都有：

- **Chrome 应用商店**（`/dl/chrome-web-store`）：自动更新。
- **开发者模式**（`/dl/browser-extension`）：下载 zip，解压后在 `chrome://extensions` 里「加载已解压的扩展程序」。不会自动更新。

两种装法的扩展 ID 一样，都是 `jfjagocghaaheooicmdnhcholmgdkngk`：开发者模式的 zip 里 `manifest.json` 带着 `key`，商店版是第一次上传时带上私钥 `key.pem` 定下的（见 [docs/browser-extension-store](browser-extension-store/README.md#第一次上传)）。应用只认这个 ID（`BrowserBridge.extensionIds`），CI 会检查 `key` 算出来的 ID 和它一致。私钥在 `~/.baocode-signing/browser-extension.pem`，丢了也不影响已上架的扩展（商店有自己的签名），但开发者模式的 ID 就没法再算出来了，务必另存一份。

```sh
# 先改 browser_extension/manifest.json 的 version（商店要求每次上传版本号都更大）
git tag extension-v0.2.0 && git push origin extension-v0.2.0         # 发布：标签要和 manifest 的版本一致
git tag extension-test-foo && git push origin extension-test-foo     # 只打包，传到 dl.baocode.dev/test/extension-…
```

本地打包：`tool/pack_browser_extension.sh`，产物在 `build/browser_extension/`。

CI 做的事：

| Job | 做什么 |
| --- | --- |
| `pack` | 标签和版本一致；`node --check` 检查 `background.js`；`key` 算出的 ID 等于应用认的 ID；manifest 里提到的文件都在；打两个 zip。改了扩展的 PR 也会跑这一步 |
| `share` | `extension-test-*`：两个 zip 都传到 `test/` |
| `publish` | 开发者模式的 zip 传到 `releases/extension/<版本>/`，最后写 `releases/extension/latest.json`（`version`、`pubDate`、`id`、`store`、`downloads.browser-extension`） |
| `store` | 用 Chrome Web Store API 上传商店的 zip 并提交审核，审核通过后自动上架。没配凭据就跳过，提示手动上传（凭据怎么拿见 [docs/browser-extension-store](browser-extension-store/README.md#ci-自动提交之后每个版本)） |

商店地址由官网维护：`latest.json` 的 `store`，默认是用 ID 拼出来的 `https://chromewebstore.google.com/detail/<ID>`，要换别的就在 `release` 环境的变量 `CHROME_WEB_STORE_URL` 里填，再推一次标签（或手动改 `latest.json`），不用发新版应用。官网的 `/dl/chrome-web-store` 跳过去（读不到 `latest.json` 时也跳 ID 地址）；应用里的按钮（`lib/browser/extension_store.dart`）每次运行拉一次，存在缓存目录的 `browser/store`，拉不到用上次存的，从没拉到过就用 ID 地址。

环境的部署规则里要允许 `extension-*` 标签。

**少发扩展**：扩展只做应用做不了的事：通信、共享标签页的边界（应用的任何请求都越不过它）、工具栏按钮。页面里的一切走 DevTools 协议原样转发（`cdp`，带 `sessionId` 时是页面里 iframe、worker 的会话，事件也带 `sessionId`）；标签页、窗口、分组走 `call`（`chrome.tabs.*`、`chrome.windows.*`、`chrome.tabGroups.*`，只能碰共享的标签页，返回的也只有共享的）和 `subscribe`（这几类的事件，只报共享标签页的）；行为开关走 `configure`（如 `followOpeners`：共享标签页打开的新标签页自动共享，默认开）。所以新功能基本只改应用。只有要新的浏览器权限（manifest 的 `permissions`）时才必须发新版扩展，而且用户要重新同意，尽量少加。

**能力和协议版本**：扩展新增的方法写进 `background.js` 的 `CAPABILITIES`，在握手时告诉应用，应用用 `BrowserConnection.can('…')` 判断后再用，旧扩展照样能连。只有改了已有消息的含义、旧的一方会理解错时，才把 `background.js` 的 `BRIDGE` 和 `BrowserBridge.protocol` 一起加一。版本对不上的连接，应用不用它，并在 设置 → 浏览器 里提示用户更新扩展或更新 BaoCode。商店版扩展会自动更新，通常比应用新；所以改协议时尽量让应用同时兼容旧版，先发应用、再发扩展。

**应用这边的 host**：浏览器按 native messaging 启动应用自带的 host，host 再去连应用。macOS 是 `macos/BrowserBridge/host.c`，Xcode 编进 `Contents/MacOS`，应用每次启动把 manifest 写进各浏览器的 `NativeMessagingHosts` 目录，经 Unix socket 连接。Windows 是 `windows/BrowserBridge/host.cpp`，`flutter build windows` 时编成 `baocode-browser-host.exe`，和 manifest `dev.baocode.browser.json` 一起放在 `baocode.exe` 旁边；安装包在 Chrome、Edge、Chromium 的注册表键里指向这个 manifest，卸载时删掉（Brave、Vivaldi 等读 Chrome 的键）。Windows 上 Dart 没有 Unix socket，应用改为监听 127.0.0.1 的随机端口，端口和每次启动新生成的 token 写在临时目录的 `baocode-browser.port`，host 握手时必须带上 token，否则应用直接断开。没经过安装包的本地构建没有注册表键，要测就手动加一条：`reg add HKCU\Software\Google\Chrome\NativeMessagingHosts\dev.baocode.browser /ve /d <构建目录>\dev.baocode.browser.json /f`。改扩展 ID 时 Windows 的 manifest 要一起改，`test/browser/browser_bridge_test.dart` 会检查两边一致。Linux 用的也是 `host.c`：`linux/BrowserBridge/CMakeLists.txt` 在 `flutter build linux` 时把它编成 `baocode-browser-host`，放在 `baocode` 旁边（deb 里是 `/opt/baocode/`）；应用每次启动把 manifest 写进 `~/.config/<浏览器>/NativeMessagingHosts`（设了 `XDG_CONFIG_HOME` 就用它）。socket 放在 `$XDG_RUNTIME_DIR`（只有本用户能进），没有才退回 `$TMPDIR` 或 `/tmp`；`/tmp` 是所有用户共用的，所以 host 连上后会用 `SO_PEERCRED` 核对对方是不是同一个用户，不是就断开，免得别的用户抢先占住 socket、截走浏览器的消息。Snap 版 Chromium 和 Flatpak 装的浏览器有沙箱，启动不了沙箱外的 host，暂不支持，设置 → 浏览器 里会提示改用官方 deb/rpm 包。CI 的 Linux 任务装上 deb 启动后，会检查 manifest 写对了位置，并真的跑一遍 host 连上应用。
