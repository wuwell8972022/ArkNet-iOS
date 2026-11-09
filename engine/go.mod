module github.com/arknetprod2/arknet-ios/engine

go 1.24.7

require (
	// gobind 在目标模块上下文中解析 gomobile/bind 与 bind/objc 包；
	// 缺少显式 require 时会报 "unable to import bind: no Go package"。
	// 版本与 CI 安装的 gomobile/gobind 二进制保持一致（v0.1.13，即
	// Android 端 libarknet.so 构建所用版本）。
	github.com/sagernet/gomobile v0.1.13
	github.com/sagernet/sing-box v1.13.0
)
