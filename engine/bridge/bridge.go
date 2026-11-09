// Package bridge wraps libbox platform-interface callbacks so that Swift
// implementations may safely return Go nil for facets iOS does not support.
//
// libbox's internal platformInterfaceWrapper dereferences several iterator
// results unconditionally (SystemCertificates, GetInterfaces); a Go nil
// interface there would panic inside the Network Extension. This wrapper
// substitutes empty iterators and preserves everything else verbatim.
//
// The Android counterpart (libarknet.so) used the same layering: a custom
// gomobile package whose newMobileBox accepted arknet.libbox.PlatformInterface.
package bridge

import (
	libbox "github.com/sagernet/sing-box/experimental/libbox"
)

// Compile-time proof that the wrapper still satisfies the full libbox contract.
var _ libbox.PlatformInterface = (*SafePlatform)(nil)

// NewSafePlatform wraps a Swift-implemented libbox.PlatformInterface with
// nil-safe defaults. Pass the result to libbox.NewCommandServer.
// Returns (wrapper, nil) so gomobile binds it as a throwing constructor.
func NewSafePlatform(inner libbox.PlatformInterface) (*SafePlatform, error) {
	return &SafePlatform{inner: inner}, nil
}

type SafePlatform struct {
	inner libbox.PlatformInterface
}

// ---- delegated verbatim -------------------------------------------------

func (w *SafePlatform) LocalDNSTransport() libbox.LocalDNSTransport {
	return w.inner.LocalDNSTransport()
}

func (w *SafePlatform) UsePlatformAutoDetectInterfaceControl() bool {
	return w.inner.UsePlatformAutoDetectInterfaceControl()
}

func (w *SafePlatform) AutoDetectInterfaceControl(fd int32) error {
	return w.inner.AutoDetectInterfaceControl(fd)
}

func (w *SafePlatform) OpenTun(options libbox.TunOptions) (int32, error) {
	return w.inner.OpenTun(options)
}

func (w *SafePlatform) UseProcFS() bool {
	return w.inner.UseProcFS()
}

func (w *SafePlatform) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (*libbox.ConnectionOwner, error) {
	return w.inner.FindConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
}

func (w *SafePlatform) StartDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return w.inner.StartDefaultInterfaceMonitor(listener)
}

func (w *SafePlatform) CloseDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return w.inner.CloseDefaultInterfaceMonitor(listener)
}

func (w *SafePlatform) UnderNetworkExtension() bool {
	return w.inner.UnderNetworkExtension()
}

func (w *SafePlatform) IncludeAllNetworks() bool {
	return w.inner.IncludeAllNetworks()
}

func (w *SafePlatform) ReadWIFIState() *libbox.WIFIState {
	return w.inner.ReadWIFIState()
}

func (w *SafePlatform) ClearDNSCache() {
	w.inner.ClearDNSCache()
}

func (w *SafePlatform) SendNotification(notification *libbox.Notification) error {
	return w.inner.SendNotification(notification)
}

// ---- nil-guarded facets -------------------------------------------------

func (w *SafePlatform) SystemCertificates() libbox.StringIterator {
	if v := w.inner.SystemCertificates(); v != nil {
		return v
	}
	return &emptyStringIterator{}
}

func (w *SafePlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	v, err := w.inner.GetInterfaces()
	if err != nil {
		return nil, err
	}
	if v == nil {
		return &emptyNetworkInterfaceIterator{}, nil
	}
	return v, nil
}

// ---- empty iterator implementations -------------------------------------

type emptyStringIterator struct{}

func (it *emptyStringIterator) Len() int32   { return 0 }
func (it *emptyStringIterator) HasNext() bool { return false }
func (it *emptyStringIterator) Next() string  { return "" }

type emptyNetworkInterfaceIterator struct{}

func (it *emptyNetworkInterfaceIterator) Len() int32                     { return 0 }
func (it *emptyNetworkInterfaceIterator) HasNext() bool                  { return false }
func (it *emptyNetworkInterfaceIterator) Next() *libbox.NetworkInterface { return nil }

// CheckConfig validates a sing-box configuration without starting an engine
// (wraps libbox.CheckConfig). Useful from the UI process before persisting.
func CheckConfig(configContent string) error {
	return libbox.CheckConfig(configContent)
}

// Version exposes the embedded sing-box version for the About screen.
func Version() string {
	return libbox.Version()
}
