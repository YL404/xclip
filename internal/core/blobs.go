package core

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type stageDir struct {
	path string
}

func ensureLibrary(root string) error {
	if info, err := os.Stat(root); err == nil && !info.IsDir() {
		return fmt.Errorf("内容库路径不是目录: %s", root)
	}
	return os.MkdirAll(filepath.Join(root, "blobs"), 0o700)
}

func stageLibrary(root string) (*stageDir, error) {
	path, err := os.MkdirTemp(root, ".import-")
	if err != nil {
		return nil, err
	}
	return &stageDir{path: path}, nil
}

func (s *stageDir) assetPath(id string) string { return filepath.Join(s.path, id) }

func cleanupStage(stage *stageDir) { _ = os.RemoveAll(stage.path) }

func copyFile(source, destination string) ([32]byte, error) {
	var zero [32]byte
	input, err := os.Open(source)
	if err != nil {
		return zero, err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return zero, err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(output, hash), input)
	closeErr := output.Close()
	if copyErr != nil {
		return zero, copyErr
	}
	if closeErr != nil {
		return zero, closeErr
	}
	var digest [32]byte
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

func blobPath(root, digest string) string {
	return filepath.Join(root, "blobs", digest[:2], digest)
}

func commitBlob(root, stagedPath, digest string) error {
	destination := blobPath(root, digest)
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return err
	}
	if info, err := os.Stat(destination); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("附件存储路径不是普通文件: %s", digest)
		}
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.Link(stagedPath, destination); err != nil {
		if os.IsExist(err) {
			return nil
		}
		// Some filesystems do not support hard links. The source and destination are
		// normally on the same volume; retain a checked copy fallback for the rest.
		data, err := copyFile(stagedPath, destination)
		if err != nil {
			return err
		}
		if hex.EncodeToString(data[:]) != digest {
			os.Remove(destination)
			return fmt.Errorf("附件写入后哈希不一致: %s", digest)
		}
	}
	return nil
}
