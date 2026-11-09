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
brew install go xcodegen
go install github.com/sagernet/gomobile/cmd/gomobile@latest
go install github.com/sagernet/gomobile/cmd/gobind@latest
gomobile init

cd engine
gomobile bind -target=ios -iosversion 15.0 \
  -bundleid com.at.arknetprod2.ios.framework \
  -o ../ios/Frameworks/ArkNet.xcframework ./bridge
cd ..

xcodegen generate
open ArkNet.xcodeproj    # 选 ArkNet scheme → Run
```

## Codemagic 免费版打包

1. 将本仓库推到 GitHub/GitLab/Bitbucket 并在 Codemagic 关联。
2. 控制台创建环境变量组 **`arknet_signing`**（变量见 `codemagic.yaml` 头注释）。
3. Apple 后台（需**付费**开发者账号——免费账号无法签发 packet-tunnel 权限）：
   - 注册 App ID `com.at.arknetprod2.ios` 与 `com.at.arknetprod2.ios.tunnel`
   - 两者都勾选 **Network Extension** 与 **App Groups**，并把 App Group
     `group.com.at.arknetprod2.ios` 加入两个 App ID
   - App Store Connect 创建 API Key，取 issuer/key id/p8
4. push 到 `main` → 自动产出 IPA（`build/ios/ipa/*.ipa`）。

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
