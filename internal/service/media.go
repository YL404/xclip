package service

import (
	"mime"
	"net/http"
	"path/filepath"
	"strings"
)

func MediaHandler(library *Library) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		id := strings.Trim(r.URL.Path, "/")
		if id == "" || strings.Contains(id, "/") {
			http.NotFound(w, r)
			return
		}
		path, name, err := library.serve(r.Context(), id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("preview") == "1" {
			path, err = library.previewPath(r.Context(), id)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "image/jpeg")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			http.ServeFile(w, r, path+".jpg")
			return
		}
		mediaType := mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
		if strings.Contains(mediaType, "html") || strings.Contains(mediaType, "svg") {
			http.Error(w, "此格式仅以文本查看", http.StatusUnsupportedMediaType)
			return
		}
		if mediaType != "" {
			w.Header().Set("Content-Type", mediaType)
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
		http.ServeFile(w, r, path)
	})
}
