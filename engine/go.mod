module github.com/arknetprod2/arknet-ios/engine

go 1.24.7

// 说明：本工程不自建 gomobile 包，直接绑定 sing-box v1.13.0 官方
// experimental/libbox（与 sing-box-for-apple 的发布形态一致）。
//
// CI 流程：
//   git clone --depth 1 --branch v1.13.0 https://github.com/SagerNet/sing-box
//   cd sing-box && gomobile bind -target ios -o Libbox.xcframework ./experimental/libbox
//
// 之所以必须在 sing-box 源码树内执行：gobind 的 packageDir（bind/gen.go）用
// packages.Load 且不设 Dir，在「当前模块」解析 github.com/sagernet/gomobile/bind
// 与 bind/objc；独立模块会报 `unable to import bind: no Go package`。
// sing-box 的 go.mod/go.sum 已完整 require sagernet/gomobile，直接复用即可。
//
// 本文件仅用于本地 IDE/静态检查参考，不参与构建。
