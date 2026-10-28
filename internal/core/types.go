package core

import "time"

type Entry struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Summary   string    `json:"summary"`
	Note      string    `json:"note"`
	Source    string    `json:"source"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	Tags      []string  `json:"tags"`
	Assets    []Asset   `json:"assets"`
}

func (e Entry) ShortID() string { return ShortID(e.ID) }

type Asset struct {
	ID        string `json:"id"`
	Path      string `json:"path"`
	Kind      string `json:"kind"`
	MIME      string `json:"mime"`
	Size      int64  `json:"size"`
	SHA256    string `json:"sha256"`
	LocalPath string `json:"local_path"`
	Text      string `json:"-"`
	TextKind  string `json:"-"`
	Readable  bool   `json:"readable"`
}

type Import struct {
	Title    string
	Summary  string
	Note     string
	Source   string
	Paths    []string
	Text     string
	TextName string
	Tags     []string
}

type Patch struct {
	Title      *string           `json:"title"`
	Summary    *string           `json:"summary"`
	Note       *string           `json:"note"`
	Tags       *[]string         `json:"tags"`
	AssetTexts map[string]string `json:"asset_texts"`
}

type SearchOptions struct {
	Query      string
	Tags       []string
	Kind       string
	Limit      int
	AllResults bool
}

type SearchResult struct {
	Entry
	Matches []Match `json:"matches"`
}

type Match struct {
	AssetID string `json:"asset_id,omitempty"`
	Path    string `json:"path,omitempty"`
	Kind    string `json:"kind"`
	Line    int    `json:"line,omitempty"`
	Start   int    `json:"start"`
	End     int    `json:"end"`
	Count   int    `json:"count"`
	Snippet string `json:"snippet"`
}

type Tag struct {
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Count       int    `json:"count"`
}
