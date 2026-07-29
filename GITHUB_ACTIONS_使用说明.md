# 没有 Mac：使用 GitHub Actions 云端 macOS 编译

此目录已经包含 GitHub Actions 工作流：

```text
.github/workflows/build-frida-ios.yml
```

它会使用 GitHub 托管的 `macos-15` 运行器安装 Xcode 构建依赖，编译 Frida 17.5.0，并上传三个 DEB 安装包。你自己的电脑可以是 Windows 或 Ubuntu，不需要本地 Mac。

## 一、浏览器操作

1. 登录 GitHub，新建一个仓库。建议临时创建公开仓库；不要上传 Apple 证书、密码或设备数据。
2. 解压本构建包，将解压后的所有内容上传到仓库根目录。
3. 必须确认隐藏目录也已上传：

   ```text
   .github/workflows/build-frida-ios.yml
   ```

4. 打开仓库顶部的 **Actions**。
5. 左侧选择 **Build Frida 17.5.0 Universal iOS DEB**。
6. 点击 **Run workflow**，再次点击绿色的 **Run workflow**。
7. 等待任务完成。首次完整构建可能耗时较长。
8. 打开已完成的运行记录，在页面底部 **Artifacts** 下载：

   ```text
   frida-17.5.0-iphone13-ios16.6-universal-debs
   ```

## 二、产物选择

解压 Artifact 后会看到：

```text
frida_17.5.0_iphoneos-arm64_universal.deb
frida_17.5.0_iphoneos-arm64e_universal.deb
frida_17.5.0_iphoneos-arm_universal.deb
BUILD-INFO.txt
SHA256SUMS
```

对应关系：

- 普通 Dopamine/rootless：`iphoneos-arm64_universal.deb`
- RootHide：`iphoneos-arm64e_universal.deb`
- rootful：`iphoneos-arm_universal.deb`

iPhone 13 使用普通 Dopamine rootless 时，应选择 `iphoneos-arm64`，不要因为 A15 支持 arm64e 就选择 RootHide 包。

## 三、Windows 上传仓库的简便方式

安装 Git 后，在解压目录执行：

```powershell
git init
git add .
git commit -m "Build Frida 17.5.0 universal iOS"
git branch -M main
git remote add origin https://github.com/你的账号/你的仓库.git
git push -u origin main
```

也可以直接使用 GitHub Desktop，选择“Add existing repository”，然后发布仓库。

## 四、安装到 iPhone

Windows/Ubuntu 先建立 USB SSH 转发：

```text
iproxy 2222 22
```

上传并安装普通 rootless 包：

```bash
scp -P 2222 frida_17.5.0_iphoneos-arm64_universal.deb root@127.0.0.1:/var/mobile/
ssh -p 2222 root@127.0.0.1

dpkg -i /var/mobile/frida_17.5.0_iphoneos-arm64_universal.deb
launchctl kickstart -k system/re.frida.server
```

主机端固定同版本：

```powershell
py -3.11 -m venv frida175
.\frida175\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install "frida==17.5.0" frida-tools
frida --version
frida-ps -Uai
```

## 五、构建失败时重点查看

### `No space left on device`

Frida 完整构建占用较大。重新运行前可在工作流的依赖安装步骤后加入清理操作，或改用有更大磁盘的付费 macOS larger runner。

### `frida-cert` 不存在

云端运行器没有你的证书。构建脚本会自动回退到 ad-hoc 签名。多数现代越狱环境可使用；若设备严格要求专用 `frida-cert`，需使用自己控制的 Mac 或云 Mac，并安全导入证书。

### `ios-arm64e` 编译失败

打开 Actions 日志，记录 Xcode、SDK 和 Meson 的第一处错误。不要只截取最后一行。

### Artifact 中没有 DEB

工作流会将此情况标记为失败。检查 `Build Frida 17.5.0 universal iOS packages` 步骤的完整日志。

## 六、限制

该工作流不包含旧 arm64e OABI slice，因为 GitHub 托管运行器不提供 Xcode 11.7。iPhone 13 + iOS 16.6 通常需要的是当前 arm64e ABI，以及同时包含 arm64、arm64e 的通用 agent；旧 OABI 主要服务更早系统环境。
