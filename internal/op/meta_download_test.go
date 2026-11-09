package op

import (
	"fmt"
	"path"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/errs"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

func TestGetFileDownloadMeta(t *testing.T) {
	metas := []model.Meta{
		{Path: "/", DownloadPolicy: "disabled", DownloadSub: true},
		{Path: "/library", DownloadPolicy: "enabled", DownloadSub: true},
		{Path: "/library/readme", Readme: "notes"},
		{Path: "/library/private", DownloadPolicy: "disabled", DownloadSub: false},
		{Path: "/library/private/child", DownloadPolicy: "inherit"},
		{Path: "/closed", DownloadPolicy: "disabled", DownloadSub: true},
		{Path: "/closed/exception", DownloadPolicy: "enabled", DownloadSub: true},
	}
	nearest := func(current string) (*model.Meta, error) {
		for {
			for i := range metas {
				if strings.EqualFold(metas[i].Path, current) {
					return &metas[i], nil
				}
			}
			if current == "/" {
				return nil, errs.MetaNotFound
			}
			current = path.Dir(current)
		}
	}
	for _, tc := range []struct{ folder, want string }{
		{"/library", "/library"},
		{"/library/sub/deep", "/library"},
		{"/library/readme/sub", "/library"},
		{"/library/private", "/library/private"},
		{"/library/private/child", "/library"},
		{"/closed/exception/deep", "/closed/exception"},
		{"/closed/other", "/closed"},
		{"/library-other", "/"},
		{"/LIBRARY/README/sub/../sub/", "/library"},
		{"/", "/"},
	} {
		t.Run(tc.folder, func(t *testing.T) {
			meta, err := getFileDownloadMeta(tc.folder, nearest)
			if err != nil || meta == nil || meta.Path != tc.want {
				t.Fatalf("got %+v, %v; want %s", meta, err, tc.want)
			}
		})
	}
}

func TestGetFileDownloadMetaWithoutPolicy(t *testing.T) {
	meta, err := getFileDownloadMeta("/folder", func(string) (*model.Meta, error) {
		return &model.Meta{Path: "/", DownloadPolicy: "inherit"}, nil
	})
	if meta != nil || err != nil {
		t.Fatalf("expected global fallback, got %+v %v", meta, err)
	}
	meta, err = getFileDownloadMeta("/folder", func(string) (*model.Meta, error) {
		return nil, errs.MetaNotFound
	})
	if meta != nil || err != nil {
		t.Fatalf("missing metadata should use global fallback, got %+v %v", meta, err)
	}
	dbErr := fmt.Errorf("database unavailable")
	_, err = getFileDownloadMeta("/folder", func(string) (*model.Meta, error) {
		return nil, dbErr
	})
	if err != dbErr {
		t.Fatalf("database error was swallowed: %v", err)
	}
}
