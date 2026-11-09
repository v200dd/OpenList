package handles

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
)

func TestMetaDownloadPolicyRejectsInvalidValue(t *testing.T) {
	for _, handler := range []gin.HandlerFunc{CreateMeta, UpdateMeta} {
		recorder := invokeHandler(t, &model.User{Role: model.ADMIN}, map[string]any{
			"path": "/test", "download_policy": "invalid",
		}, handler)
		if !strings.Contains(recorder.Body.String(), `"code":400`) {
			t.Fatalf("invalid policy accepted: %s", recorder.Body.String())
		}
	}
}

func TestFolderDownloadPolicyIntegration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	root := t.TempDir()
	folder := "download-policy-test"
	for _, dir := range []string{folder, folder + "/child", folder + "/exception", "download-policy-sibling"} {
		if err := os.MkdirAll(filepath.Join(root, "team/a", dir), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "team/a", dir, "file.txt"), []byte("test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	user := setupBackslashTraversalTest(t, root, 0)
	if err := op.SaveSettingItems([]model.SettingItem{{Key: conf.EnableFileDownload, Value: "true", Type: conf.TypeBool, Group: model.GLOBAL, Flag: model.PUBLIC}}); err != nil {
		t.Fatal(err)
	}
	metas := []model.Meta{
		{Path: "/team/a/" + folder, DownloadPolicy: "disabled", DownloadSub: true},
		{Path: "/team/a/" + folder + "/child", Readme: "child notes"},
		{Path: "/team/a/" + folder + "/exception", DownloadPolicy: "enabled", DownloadSub: true},
	}
	for i := range metas {
		recorder := invokeHandler(t, &model.User{Role: model.ADMIN}, metas[i], CreateMeta)
		if !strings.Contains(recorder.Body.String(), `"code":200`) {
			t.Fatalf("metadata creation failed: %s", recorder.Body.String())
		}
		persisted, err := db.GetMetaByPath(metas[i].Path)
		if err != nil {
			t.Fatal(err)
		}
		metas[i] = *persisted
	}
	if metas[1].DownloadPolicy != model.DownloadPolicyInherit {
		t.Fatalf("empty policy did not default to inherit: %+v", metas[1])
	}
	t.Cleanup(func() {
		for i := range metas {
			_ = op.DeleteMetaById(metas[i].ID)
		}
	})
	check := func(reqPath string, want bool) {
		t.Helper()
		for _, tc := range []struct {
			path    string
			handler gin.HandlerFunc
		}{
			{reqPath, FsListSplit}, {reqPath, FsGetSplit}, {reqPath + "/file.txt", FsGetSplit},
		} {
			recorder := invokeHandler(t, user, map[string]any{"path": tc.path}, tc.handler)
			var resp struct {
				Code int `json:"code"`
				Data struct {
					Enabled *bool `json:"enable_file_download"`
				} `json:"data"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &resp); err != nil {
				t.Fatal(err)
			}
			if resp.Code != 200 || resp.Data.Enabled == nil || *resp.Data.Enabled != want {
				t.Fatalf("path=%s role=%d want=%t: %s", tc.path, user.Role, want, recorder.Body.String())
			}
		}
	}
	check("/"+folder, false)
	check("/"+folder+"/child", false)
	check("/"+folder+"/exception", true)
	check("/download-policy-sibling", true)
	if err := op.SaveSettingItems([]model.SettingItem{{Key: conf.EnableFileDownload, Value: "false", Type: conf.TypeBool, Group: model.GLOBAL, Flag: model.PUBLIC}}); err != nil {
		t.Fatal(err)
	}
	check("/download-policy-sibling", false)
	check("/"+folder+"/exception", true)
	user.Role = model.ADMIN
	check("/"+folder, true)
	check("/download-policy-sibling", true)

	// Persisting false must really disable inheritance, not be skipped by GORM.
	metas[0].DownloadSub = false
	recorder := invokeHandler(t, &model.User{Role: model.ADMIN}, metas[0], UpdateMeta)
	if !strings.Contains(recorder.Body.String(), `"code":200`) {
		t.Fatalf("metadata update failed: %s", recorder.Body.String())
	}
	persisted, err := db.GetMetaById(metas[0].ID)
	if err != nil || persisted.DownloadSub || persisted.DownloadPolicy != "disabled" {
		t.Fatalf("policy did not persist: %+v %v", persisted, err)
	}
	if err := op.SaveSettingItems([]model.SettingItem{{Key: conf.EnableFileDownload, Value: "true", Type: conf.TypeBool, Group: model.GLOBAL, Flag: model.PUBLIC}}); err != nil {
		t.Fatal(err)
	}
	user.Role = model.GENERAL
	check("/"+folder, false)
	check("/"+folder+"/child", true)
}
