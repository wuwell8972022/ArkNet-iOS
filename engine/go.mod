module github.com/arknetprod2/arknet-ios/engine

go 1.24.7

// 注意：本模块不参与 gomobile 构建。CI 会把 engine/arknet/arknet.go 复制进
// sing-box v1.13.0 源码树的 experimental/arknet/，并在该模块内执行
// `gomobile bind ./experimental/arknet`。
//
// 原因：gobind 在「目标模块」的上下文中解析 github.com/sagernet/gomobile/bind
// 与 bind/objc（bind/gen.go 的 packageDir 使用 packages.Load，无 Dir 参数），
// 独立模块即便显式 require gomobile，也会因依赖图/go.sum 不完整而报
// `unable to import bind: no Go package`。放在 sing-box 模块内则复用其
// 完整的 go.mod / go.sum，与上游 build_libbox 完全一致。
//
// 此处保留 go.mod 仅用于本地 IDE/静态检查。

require (
	github.com/sagernet/gomobile v0.1.13
	github.com/sagernet/sing-box v1.13.0
)
