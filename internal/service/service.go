package service

import (
	"context"
	"errors"
	"os"
	"sync"
	"time"

	"github.com/YL404/xclip/internal/core"
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
)

var LibraryChanged = mygo.NewEvent[struct{}]("library:changed")

type Library struct {
	mu   sync.Mutex
	root string
	db   *core.Store
}

func NewLibrary(root string) *Library { return &Library{root: root} }

// Watch 每 2 秒检查其他进程的提交，发现变化后广播 library:changed。
func (l *Library) Watch(ctx context.Context) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	var last int64
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		store, err := l.store(ctx)
		if err != nil {
			continue
		}
		version, err := store.DataVersion(ctx)
		if err != nil {
			continue
		}
		if last != 0 && version != last {
			LibraryChanged.Broadcast(struct{}{})
		}
		last = version
	}
}

func (l *Library) open(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.db != nil {
		return nil
	}
	store, err := core.Open(ctx, l.root)
	if err != nil {
		return err
	}
	l.db = store
	return nil
}

func (l *Library) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.db == nil {
		return
	}
	_ = l.db.Close()
	l.db = nil
}

func (l *Library) store(ctx context.Context) (*core.Store, error) {
	if err := l.open(ctx); err != nil {
		return nil, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.db, nil
}

func (l *Library) Search(ctx context.Context, query string, tags []string, kind string) ([]core.SearchResult, error) {
	store, err := l.store(ctx)
	if err != nil {
		return nil, err
	}
	return store.Search(ctx, core.SearchOptions{Query: query, Tags: tags, Kind: kind, AllResults: true})
}

func (l *Library) Get(ctx context.Context, id string) (core.Entry, error) {
	store, err := l.store(ctx)
	if err != nil {
		return core.Entry{}, err
	}
	return store.Get(ctx, id)
}

func (l *Library) Text(ctx context.Context, id, path string) (string, error) {
	store, err := l.store(ctx)
	if err != nil {
		return "", err
	}
	return store.AssetText(ctx, id, path)
}

func (l *Library) Tags(ctx context.Context) ([]core.Tag, error) {
	store, err := l.store(ctx)
	if err != nil {
		return nil, err
	}
	return store.Tags(ctx)
}

func (l *Library) Update(ctx context.Context, patch core.Patch, id string) (core.Entry, error) {
	store, err := l.store(ctx)
	if err != nil {
		return core.Entry{}, err
	}
	entry, err := store.Patch(ctx, id, patch)
	if err == nil {
		LibraryChanged.Broadcast(struct{}{})
	}
	return entry, err
}

func (l *Library) Import(ctx context.Context, paths []string) (core.Entry, error) {
	store, err := l.store(ctx)
	if err != nil {
		return core.Entry{}, err
	}
	entry, err := store.Import(ctx, core.Import{Paths: paths})
	if err == nil {
		LibraryChanged.Broadcast(struct{}{})
	}
	return entry, err
}

func (l *Library) ChooseAndImport(ctx context.Context) (core.Entry, error) {
	window := mygo.CallerWindow(ctx)
	if window == nil {
		return core.Entry{}, errors.New("无法取得当前窗口")
	}
	paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Parent: window, Directory: true, Title: "选择要收录的文件夹"})
	if err != nil || len(paths) == 0 {
		return core.Entry{}, err
	}
	return l.Import(ctx, paths)
}

func (l *Library) ChooseFilesAndImport(ctx context.Context) (core.Entry, error) {
	window := mygo.CallerWindow(ctx)
	if window == nil {
		return core.Entry{}, errors.New("无法取得当前窗口")
	}
	paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Parent: window, Multiple: true, Title: "选择要收录的文件"})
	if err != nil || len(paths) == 0 {
		return core.Entry{}, err
	}
	return l.Import(ctx, paths)
}

func (l *Library) Copy(text string) error { return mygo.Clipboard.Write(transfer.TextData(text)) }

func (l *Library) Reveal(ctx context.Context, assetID string) error {
	store, err := l.store(ctx)
	if err != nil {
		return err
	}
	path, _, err := store.AssetPath(ctx, assetID)
	if err != nil {
		return err
	}
	mygo.Shell.ShowItemInFolder(path)
	return nil
}

func (l *Library) serve(ctx context.Context, id string) (string, string, error) {
	store, err := l.store(ctx)
	if err != nil {
		return "", "", err
	}
	path, name, err := store.AssetPath(ctx, id)
	if err != nil {
		return "", "", err
	}
	if _, err := os.Stat(path); err != nil {
		return "", "", err
	}
	return path, name, nil
}
