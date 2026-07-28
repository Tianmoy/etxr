//go:build !linux

package dataplane

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
)

var fallbackLocks sync.Map

type fileLock struct {
	mutex *sync.Mutex
	file  *os.File
}

func acquireFileLock(path string) (*fileLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	mutexValue, _ := fallbackLocks.LoadOrStore(path, &sync.Mutex{})
	mutex := mutexValue.(*sync.Mutex)
	mutex.Lock()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		mutex.Unlock()
		return nil, err
	}
	return &fileLock{mutex: mutex, file: file}, nil
}

func (lock *fileLock) Close() error {
	err := lock.file.Close()
	lock.mutex.Unlock()
	return err
}

func replaceFile(source, destination string) error {
	err := os.Rename(source, destination)
	if err == nil {
		return nil
	}
	if !errors.Is(err, os.ErrExist) && !errors.Is(err, os.ErrPermission) {
		return err
	}
	if removeErr := os.Remove(destination); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
		return err
	}
	return os.Rename(source, destination)
}

func syncDirectory(string) error {
	return nil
}
