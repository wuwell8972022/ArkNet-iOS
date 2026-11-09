# ArkNet iOS — 安心加速器 iOS 移植工程

Android 客户端（`com.at.arknetprod2` v1.0.1，sing-box 1.13.0 内核）的 iOS 平台
完整移植工程。BFF 协议、加密签名、节点凭据模型、分流语义与 Android 端逐项对齐。

## 架构总览

```
┌─ ArkNet (App, SwiftUI) ─────────────────────────────────────────┐
│ BFFClient + ContentSecuritySigner   ← X-Content-Security 签名协议 │
│ APIService（36 端点）UserSession     ← Bearer / X-Renewed-Token  │
│ VPNManager                          ← connect/check/disconnect   │
│ TunnelConfigBuilder                 ← Profile → sing-box v1.13   │
│ TunnelCommandClient                 ← libbox.CommandClient       │
│     (流量/日志/urltest 流式回调, unix socket @ App Group)         │
└──────────────┬───────────────────────────────────────────────────┘
               │  App Group (group.com.at.arknetprod2.ios)
               │  config.json / 断连兜底 token / Darwin 通知
┌─ ArkNetTunnel (NE, PacketTunnelProvider) ────────────────────────┐
│ libbox.CommandServer   ← startOrReloadService(configJSON)        │
│ SafePlatform → libbox.PlatformInterface (openTun → packetFlow fd)│
│ sing-box 1.13.0 (ArkNet.xcframework, gomobile bind)              │
└──────────────────────────────────────────────────────────────────┘
```

## 目录结构

```
ArkNet-iOS/
├ codemagic.yaml          # 免费版 CI（Go→xcframework→XcodeGen→IPA）
├ project.yml             # XcodeGen 工程定义（双 target + 共享源）
├ engine/
│   ├ go.mod              # pin github.com/sagernet/sing-box v1.13.0
│   └ bridge/bridge.go    # SafePlatform nil-guard（防 Swift→Go nil panic）
│                         # + CheckConfig / Version 暴露
└ ios/
    ├ App/                # SwiftUI 主应用（协议层 + 全部页面）
    ├ Tunnel/             # PacketTunnelProvider（CommandServerHandler +
    │                     #  PlatformInterface 双协议实现，fd KVC 桥）
    ├ Shared/             # SharedStore(App Group) / TunnelStatusWriter
    ├ Resources/          # client-bff-rsa-prod2.public.pem + 3 个 .srs
    └ Frameworks/         # ArkNet.xcframework（CI 产出，不入库）
```

## 本地构建（需 macOS + Xcode 15.3+ + Go 1.24+，部署目标 iOS 16.0）

```bash
brew install xcodegen
# Go 必须固定为 sing-box v1.13.0 go.mod 声明的 1.24.7
curl -fsSL https://go.dev/dl/go1.24.7.darwin-arm64.tar.gz -o /tmp/go.tgz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
export PATH="/usr/local/go/bin:$PATH"

# gomobile 版本必须与 sing-box v1.13.0 的 require 一致（v0.1.12）
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
gomobile init

# 1. 取 sing-box v1.13.0 源码树，注入 arknet 包（不改 go.mod）
git clone --depth 1 --branch v1.13.0 https://github.com/SagerNet/sing-box sing-box-src
mkdir -p sing-box-src/experimental/arknet
cp engine/arknet/arknet.go sing-box-src/experimental/arknet/
cd sing-box-src
export GOTOOLCHAIN=local

# 2. 只启用产品需要的标签（不要加 with_tailscale，见下文）
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,badlinkname,tfogo_checklinkname0,grpcnotrace"
gomobile bind -v -target ios \
  -o ../ios/Frameworks/ArkNet.xcframework \
  -tags-not-macos=with_low_memory -tags "$TAGS" \
  ./experimental/arknet
cd ..

xcodegen generate
open ArkNet.xcodeproj    # 选 ArkNet scheme → Run
```

> **构建三个必须遵守的约束**（都已踩过坑）：
>
> 1. **必须在 sing-box 源码树内构建**：`gobind` 的 `packageDir`
>    （`bind/gen.go`）用 `packages.Load`（无 `Dir`）在**当前模块**里解析
>    `github.com/sagernet/gomobile/bind(/objc)`。独立模块即使显式 require
>    gomobile 也会报 `unable to import bind: no Go package`。
> 2. **Go 固定 1.24.7**：更新版本（1.25/1.26）的 `encoding/json/v2` 实验差异会让
>    `github.com/go-json-experiment/json` 报 `undefined: json.SkipFunc`。
> 3. **不要启用 `with_tailscale`**：该标签拉入 tailscale/kube/ssh 依赖链
>    （上述 json 报错正是来自它），本项目不需要，去掉还能显著缩短构建。
>
> **ObjC 类名前缀**：`bind/genobjc.go: namePrefixOf = Prefix + Title(pkg.Name())`，
> 因此 libbox 的类型是 `Libbox*`（`LibboxPlatformInterfaceProtocol` 等），
> 本工程的 arknet 包是 `Arknet*`（`ArknetNewSafePlatform`）。Swift 里不要
> 自己起名，必须使用生成名。

## Codemagic 打包

**当前 `codemagic.yaml` 为最简 Debug 工作流**：零凭据、零环境变量组，
推到仓库后在 Codemagic 关联即可跑：

> 工具链安装 → `ArkNet.xcframework`（sing-box 1.13.0 libbox）→
> XcodeGen → `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）→ 未签名 debug IPA

产物：`ArkNet-debug-unsigned.ipa` + `.app`（编译验证用途）。
**该 IPA 无法直接真机安装**——接入签名后才能分发：

1. Apple 后台（需**付费**开发者账号，免费账号签不了 packet-tunnel 权限）：
   注册 `com.at.arknetprod2.ios` / `...ios.tunnel` 两个 App ID，
   勾选 Network Extension + App Groups（`group.com.at.arknetprod2.ios`）。
2. 创建 App Store Connect API Key，取 issuer id / key id / `.p8` 私钥。
3. 在工作流里加回签名步骤（环境变量组 `arknet_signing`）：
   ```yaml
   environment:
     groups:
       - arknet_signing   # APP_STORE_CONNECT_ISSUER_ID / KEY_IDENTIFIER /
                          # APP_STORE_CONNECT_PRIVATE_KEY / CERTIFICATE_PRIVATE_KEY
   scripts:
     - name: 配置签名
       script: xcode-project use-profiles
   ```
   并把 build 脚本替换为：
   ```yaml
   - name: 打包 IPA
     script: xcode-project build-ipa --project ArkNet.xcodeproj --scheme ArkNet --method ad-hoc
   ```
   （Codemagic CLI 工具会自动读取上述标准变量名，无需在 YAML 里声明
   `environment.app_store_connect` 块——该块即此前 schema 校验报错的原因。）

## 与 Android 端的功能对齐矩阵

| Android | iOS 本工程 | 状态 |
|---|---|---|
| VPNService(TUN) + libbox | NEPacketTunnelProvider + libbox CommandServer | ✅ |
| Box.startOrReload(profile) | config.json @ App Group + startOrReloadService | ✅ |
| 智能/全局/指定模式 | smart/global/specified(=smart)/protect(断连保护=block) | ✅ |
| .srs 分流 (geoip/geosite) | Bundle 内 .srs → App Group 拷贝 → local rule_set | ✅ |
| FakeIP | dns.fakeip server (198.18.0.0/15) + tun-in 规则 | ✅ |
| X-Content-Security 签名 | ContentSecuritySigner (AES-ECB/HMAC/RSA-PKCS1) | ✅ |
| 403/9010 时钟校准重签 | BFFClient.perform 内置 | ✅ |
| X-Renewed-Token 静默换票 | BFFClient / UserSession.applyRenewedToken | ✅ |
| disconnect 兜底 token | SharedStore.disconnectToken | ✅ |
| 通信域名竞速 (v10) | raceCandidates + initialization 未签名竞速 | ✅ |
| 滑块验证码 SlideCaptchaView | SlideCaptchaView (masterImage/tileImage/tileX) | ✅ |
| 设备顶号 (evictedDeviceId) | LoginView 提示 + 设备管理列表/解绑 | ✅ |
| 12 别名图标伪装 | (iOS 可用 CFBundleAlternateIcons，未内置) | ⏳ |
| 厂商保活引导页 | 不适用（NE 常驻替代） | — |
| 应用内 APK 更新 | 走 App Store（update API 仍可用作版本提示） | 🔄 |
| WebView 门户 + JS 桥 | WKWebView + nativeObject handler（协议一致） | ✅ |
| 会员支付占位 UI | 同为占位（IAP 契约确定后接 StoreKit 2） | 🔄 |

## 已知限制与待确认项

1. **权益端点路径**：`/api/v1/users/me/entitlement` 为按实体字段推断的
   best-effort 路径，Android 反编译中未直接出现（可能内嵌于 /users/me），
   联调时以服务端实际为准。
2. **proto 映射**：`NodeConnectData.proto` 由服务端下发；本工程支持
   vless/vmess/trojan/hysteria2/shadowsocks(含 `proto:method` 透传)/tuic。
   shadowsocks 默认 `aes-256-gcm`，服务端若使用 2022 系列需以
   `shadowsocks:2022-blake3-aes-256-gcm` 形式下发或联系调整。
3. **AES-ECB**：BFF 遗留协议强制 ECB，仅限 ContentSecuritySigner 内使用；
   建议后续与 BFF 协商升级 AES-GCM。
4. **H5 桥回调**：NativeObject.js 的 iOS 回调通道
   (`window.webkit.messageHandlers.nativeObject`) 已实现 toast/openUrl/vibrate；
   其余 command 按需在 `NavView.swift::Coordinator.handle` 中扩展。
5. **并发严格模式**：工程按 Swift 5 语言模式编译（minimal concurrency），
   迁移 Swift 6 strict 需处理 NE 回调的隔离标注。

## 测试要点（联调清单）

- [ ] 冷启动 → initialization 竞速（三个端点）→ communication-domains 落库
- [ ] 登录（验证码滑块）→ 顶号提示 → token 落 App Group
- [ ] 连接 → openTun fd 交接 → 引擎启动 → status 流 (uplink/downlink)
- [ ] 模式切换 → ServiceReload → 分流生效（CN 直连 / 全局代理）
- [ ] 节点切换 → config 重建 → urltest 延迟回显
- [ ] 断开 → /nodes/disconnect（含 token 失效场景兜底）
