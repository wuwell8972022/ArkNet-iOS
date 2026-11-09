// Package arknet is a thin, iOS-aware guard layer over sing-box's libbox
// platform interface, compiled into the same gomobile framework as libbox.
//
// Why this exists (matching how the Android client packaged its engine):
//
//   - libbox's platformInterfaceWrapper dereferences several values without
//     a nil check (SystemCertificates, GetInterfaces, ReadWIFIState,
//     FindConnectionOwner). A Network Extension returning ObjC nil produces a
//     non-nil Go proxy wrapping nil, which then panics inside the engine.
//   - iOS has no equivalent for WiFi-state, procfs or connection-owner lookup,
//     so those facets are short-circuited here instead of being delegated.
//
// Build together with libbox inside a sing-box checkout:
//
//	cp -R engine/arknet <sing-box>/experimental/arknet
//	gomobile bind -target ios,iossimulator -o ArkNet.xcframework ./experimental/arknet
//
// Package name "arknet" makes gomobile prefix generated ObjC classes with
// "Arknet" (bind/genobjc.go: namePrefixOf = Prefix + Title(pkg.Name())).
package arknet

import (
	libbox "github.com/sagernet/sing-box/experimental/libbox"
	E "github.com/sagernet/sing/common/exceptions"
)

// Compile-time proof the guard still satisfies the full libbox contract.
var _ libbox.PlatformInterface = (*SafePlatform)(nil)

// NewSafePlatform wraps the Swift-implemented platform interface.
// Returns (wrapper, error) so gomobile binds it as a throwing constructor.
func NewSafePlatform(inner libbox.PlatformInterface) (*SafePlatform, error) {
	return &SafePlatform{inner: inner}, nil
}

// SafePlatform delegates the facets iOS genuinely implements (TUN hand-off,
// interface enumeration, path monitoring) and answers the rest safely.
type SafePlatform struct {
	inner libbox.PlatformInterface
}

// ---- delegated ----------------------------------------------------------

func (w *SafePlatform) OpenTun(options libbox.TunOptions) (int32, error) {
	return w.inner.OpenTun(options)
}

func (w *SafePlatform) UsePlatformAutoDetectInterfaceControl() bool {
	return w.inner.UsePlatformAutoDetectInterfaceControl()
}

func (w *SafePlatform) AutoDetectInterfaceControl(fd int32) error {
	return w.inner.AutoDetectInterfaceControl(fd)
}

func (w *SafePlatform) StartDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return w.inner.StartDefaultInterfaceMonitor(listener)
}

func (w *SafePlatform) CloseDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return w.inner.CloseDefaultInterfaceMonitor(listener)
}

func (w *SafePlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	iterator, err := w.inner.GetInterfaces()
	if err != nil {
		return nil, err
	}
	if iterator == nil {
		return &emptyNetworkInterfaceIterator{}, nil
	}
	return iterator, nil
}

func (w *SafePlatform) ClearDNSCache() {
	w.inner.ClearDNSCache()
}

func (w *SafePlatform) SendNotification(notification *libbox.Notification) error {
	return w.inner.SendNotification(notification)
}

// ---- short-circuited (no iOS equivalent / nil-proxy hazard) --------------

// UseProcFS is Android-only.
func (w *SafePlatform) UseProcFS() bool { return false }

// UnderNetworkExtension is always true for a Packet Tunnel Provider.
func (w *SafePlatform) UnderNetworkExtension() bool { return true }

// IncludeAllNetworks stays false: we route only default traffic.
func (w *SafePlatform) IncludeAllNetworks() bool { return false }

// LocalDNSTransport: the client never configures a "local" DNS server type,
// and a nil proxy would be dereferenced by baseContext().
func (w *SafePlatform) LocalDNSTransport() libbox.LocalDNSTransport { return nil }

// ReadWIFIState: iOS requires entitlement-gated NEHotspotNetwork; unused here.
func (w *SafePlatform) ReadWIFIState() *libbox.WIFIState { return nil }

// SystemCertificates: not used by our DNS/TLS configuration.
func (w *SafePlatform) SystemCertificates() libbox.StringIterator {
	return &emptyStringIterator{}
}

// FindConnectionOwner: unsupported on iOS (returns an error, never nil,nil).
func (w *SafePlatform) FindConnectionOwner(
	ipProtocol int32,
	sourceAddress string,
	sourcePort int32,
	destinationAddress string,
	destinationPort int32,
) (*libbox.ConnectionOwner, error) {
	return nil, E.New("find connection owner is unsupported on iOS")
}

// ---- helpers -----------------------------------------------------------

// CheckConfig validates a sing-box configuration without starting the engine.
func CheckConfig(configContent string) error {
	return libbox.CheckConfig(configContent)
}

// Version reports the embedded sing-box version (About screen).
func Version() string {
	return libbox.Version()
}

type emptyStringIterator struct{}

func (it *emptyStringIterator) Len() int32    { return 0 }
func (it *emptyStringIterator) HasNext() bool { return false }
func (it *emptyStringIterator) Next() string  { return "" }

type emptyNetworkInterfaceIterator struct{}

func (it *emptyNetworkInterfaceIterator) Len() int32                     { return 0 }
func (it *emptyNetworkInterfaceIterator) HasNext() bool                  { return false }
func (it *emptyNetworkInterfaceIterator) Next() *libbox.NetworkInterface { return nil }
