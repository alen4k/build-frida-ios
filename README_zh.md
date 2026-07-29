# Frida 17.5.0：iPhone 13 / iOS 16.6 通用构建包

> **没有 Mac：** 请直接阅读 `GITHUB_ACTIONS_使用说明.md`。包内已提供 GitHub Actions 云端 macOS 一键构建工作流。

这个构建包用于解决官方 DEB 在部分 iPhone 13 + iOS 16.6 越狱环境中出现的：

```text
Failed to spawn: incompatible Mach-O image
```

核心处理是生成同时包含 **arm64 + arm64e** 的 `frida-agent.dylib`。第三方 App 通常使用 arm64，Safari、SpringBoard 等系统进程可能使用 arm64e；agent 缺任意一个 slice 都可能在注入时触发 Mach-O 不兼容。

> 当前压缩包包含可直接运行的 macOS 构建脚本，不包含已经编译的 DEB。Frida iOS 构建依赖 Xcode、iPhoneOS SDK、lipo 和 codesign，必须在 macOS 上完成。

## 1. 环境要求

- macOS；
- 完整 Xcode，并运行过一次初始化；
- Python 3；
- Node.js；
- GNU Make；
- dpkg。

安装常用依赖：

```bash
xcode-select --install
brew install make dpkg node python@3.12
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

## 2. 构建 iPhone 13 / iOS 16.6 版本

```bash
chmod +x build_frida_17.5.0_universal_ios.sh
./build_frida_17.5.0_universal_ios.sh
```

默认不构建旧 arm64e ABI。iPhone 13 的 iOS 16.6 使用当前 arm64e ABI，修复 Mach-O 问题的关键是 agent 同时包含 arm64 和 arm64e。

需要完全复刻包含旧 ABI 的三 slice server 时：

```bash
export XCODE11=/Applications/Xcode-11.7.app
./build_frida_17.5.0_universal_ios.sh --include-oabi
```

完成后会产生：

```text
release-frida-17.5.0/
├── frida_17.5.0_iphoneos-arm64_universal.deb   # Dopamine/rootless
├── frida_17.5.0_iphoneos-arm64e_universal.deb  # RootHide
├── frida_17.5.0_iphoneos-arm_universal.deb     # rootful
├── BUILD-INFO.txt
└── SHA256SUMS
```

iPhone 13 + iOS 16.6 使用 Dopamine 普通 rootless 时，选择 `iphoneos-arm64`，不要因为 A15 支持 arm64e 就误装 RootHide 的 `iphoneos-arm64e` 包。

## 3. 验证 Mach-O slices

```bash
chmod +x verify_frida_package_macos.sh
./verify_frida_package_macos.sh \
  release-frida-17.5.0/frida_17.5.0_iphoneos-arm64_universal.deb
```

必须出现：

```text
Agent architectures: arm64 arm64e
PASS: universal agent contains arm64 and arm64e
```

## 4. 安装到普通 Dopamine rootless 设备

先建立 USB SSH 转发：

```bash
iproxy 2222 22
```

另开终端：

```bash
chmod +x install_rootless_usb.sh
./install_rootless_usb.sh \
  release-frida-17.5.0/frida_17.5.0_iphoneos-arm64_universal.deb
```

也可以手工安装：

```bash
scp -P 2222 frida_17.5.0_iphoneos-arm64_universal.deb root@127.0.0.1:/var/mobile/
ssh -p 2222 root@127.0.0.1

dpkg -i /var/mobile/frida_17.5.0_iphoneos-arm64_universal.deb
launchctl kickstart -k system/re.frida.server
```

## 5. 主机客户端必须同版本

```bash
python3 -m venv frida175
source frida175/bin/activate
python -m pip install --upgrade pip
python -m pip install 'frida==17.5.0' frida-tools
frida --version
frida-ps -Uai
```

设备端和主机端应都显示 `17.5.0`。

## 6. 常见问题

### `frida-ps -Uai` 正常，但 spawn/attach 报 Mach-O 错误

重点检查：

```bash
file /var/jb/usr/lib/frida/frida-agent.dylib
```

agent 必须同时包含 arm64 与 arm64e。

### 安装包架构不匹配

- 普通 Dopamine/rootless：`iphoneos-arm64`；
- RootHide：`iphoneos-arm64e`；
- rootful：`iphoneos-arm`。

### spawn 无权限，但 attach 正常

这通常是越狱实现、launch daemon 权限或 spawn gating 问题，不是 Mach-O slice 问题。先手动打开 App，再按 PID/进程名 attach 测试。

### 代码签名失败

脚本优先使用名为 `frida-cert` 的签名身份；不存在时回退为 ad-hoc 签名。部分越狱组合要求自建 `frida-cert`，此时先在钥匙串中创建并信任该代码签名证书，再重新构建。
