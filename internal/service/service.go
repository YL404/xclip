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

// Runtime 管理内容库连接与后台监听生命周期，不直接暴露给前端 RPC。
type Runtime struct {
	mu   sync.Mutex
	root string
	db   *core.Store
}

func NewRuntime(root string) *Runtime {
	return &Runtime{root: root}
}

// Library 返回仅包含前端所需 RPC 方法的服务句柄。
func (r *Runtime) Library() *Library {
	return &Library{runtime: r}
}

// Watch 每 2 秒检查其他进程的提交，发现变化后广播 library:changed。
func (r *Runtime) Watch(ctx context.Context) {
	var last int64
	if store, err := r.store(ctx); err == nil {
		if version, err := store.DataVersion(ctx); err == nil {
			last = version
		}
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		store, err := r.store(ctx)
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

func (r *Runtime) open(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.db != nil {
		return nil
	}
	store, err := core.Open(ctx, r.root)
	if err != nil {
		return err
	}
	r.db = store
	return nil
}

func (r *Runtime) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.db == nil {
		return
	}
	_ = r.db.Close()
	r.db = nil
}

func (r *Runtime) store(ctx context.Context) (*core.Store, error) {
	if err := r.open(ctx); err != nil {
		return nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.db, nil
}

func (r *Runtime) serve(ctx context.Context, id string) (string, string, error) {
	store, err := r.store(ctx)
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

// Library 是绑定到 MyGo 前端的前端 RPC 服务。
type Library struct {
	runtime *Runtime
}

func (l *Library) Search(ctx context.Context, query string, tags []string, kind string) ([]core.SearchResult, error) {
	store, err := l.runtime.store(ctx)
	if err != nil {
		return nil, err
	}
	return store.Search(ctx, core.SearchOptions{Query: query, Tags: tags, Kind: kind, AllResults: true})
}

func (l *Library) Get(ctx context.Context, id string) (core.Entry, error) {
	store, err := l.runtime.store(ctx)
	if err != nil {
		return core.Entry{}, err
	}
	return store.Get(ctx, id)
}

func (l *Library) Text(ctx context.Context, id, path string) (string, error) {
	store, err := l.runtime.store(ctx)
	if err != nil {
		return "", err
	}
	return store.AssetText(ctx, id, path)
}

func (l *Library) Tags(ctx context.Context) ([]core.Tag, error) {
	store, err := l.runtime.store(ctx)
	if err != nil {
		return nil, err
	}
	return store.Tags(ctx)
}

func (l *Library) Update(ctx context.Context, id string, patch core.Patch) (core.Entry, error) {
	store, err := l.runtime.store(ctx)
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
	store, err := l.runtime.store(ctx)
	if err != nil {
		return core.Entry{}, err
	}
	entry, err := store.Import(ctx, core.Import{Paths: paths})
	if err == nil {
		LibraryChanged.Broadcast(struct{}{})
	}
	return entry, err
}

func (l *Library) chooseAndImport(ctx context.Context, opts mygo.OpenDialogOptions) (core.Entry, error) {
	window := mygo.CallerWindow(ctx)
	if window == nil {
		return core.Entry{}, errors.New("无法取得当前窗口")
	}
	opts.Parent = window
	paths, err := mygo.Dialog.Open(opts)
	if err != nil || len(paths) == 0 {
		return core.Entry{}, err
	}
	return l.Import(ctx, paths)
}

func (l *Library) ChooseAndImport(ctx context.Context) (core.Entry, error) {
	return l.chooseAndImport(ctx, mygo.OpenDialogOptions{Directory: true, Title: "选择要收录的文件夹"})
}

func (l *Library) ChooseFilesAndImport(ctx context.Context) (core.Entry, error) {
	return l.chooseAndImport(ctx, mygo.OpenDialogOptions{Multiple: true, Title: "选择要收录的文件"})
}

func (l *Library) Copy(text string) error {
	return mygo.Clipboard.Write(transfer.TextData(text))
}

func (l *Library) Reveal(ctx context.Context, assetID string) error {
	store, err := l.runtime.store(ctx)
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
