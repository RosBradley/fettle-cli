//go:build darwin

package main

import (
	"bytes"
	"os"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	getTermios = unix.TIOCGETA
	setTermios = unix.TIOCSETA
)

// openPTY opens a new pseudo-terminal pair: the master side stays here and
// the command gets the slave side as its terminal.
func openPTY() (master, slave *os.File, err error) {
	fd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	master = os.NewFile(uintptr(fd), "/dev/ptmx")
	slave, err = openSlave(master)
	if err != nil {
		_ = master.Close()
		return nil, nil, err
	}
	return master, slave, nil
}

func openSlave(master *os.File) (*os.File, error) {
	if err := ioctl(master, unix.TIOCPTYGRANT, 0); err != nil {
		return nil, err
	}
	if err := ioctl(master, unix.TIOCPTYUNLK, 0); err != nil {
		return nil, err
	}
	// TIOCPTYGNAME fills a 128-byte buffer with the slave's path; the
	// kernel needs the buffer's address, hence unsafe.
	name := make([]byte, 128)
	if err := ioctl(master, unix.TIOCPTYGNAME, uintptr(unsafe.Pointer(&name[0]))); err != nil { //nolint:gosec // G103: the ioctl writes into this buffer.
		return nil, err
	}
	if i := bytes.IndexByte(name, 0); i >= 0 {
		name = name[:i]
	}
	return os.OpenFile(string(name), os.O_RDWR|unix.O_NOCTTY, 0)
}

func ioctl(f *os.File, request, arg uintptr) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), request, arg); errno != 0 {
		return errno
	}
	return nil
}
