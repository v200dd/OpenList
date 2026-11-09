package common

import (
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

func TestResolveFileDownloadEnabled(t *testing.T) {
	for _, role := range []int{model.GENERAL, model.GUEST, model.ADMIN} {
		user := &model.User{Role: role}
		for _, global := range []bool{false, true} {
			for _, policy := range []string{"", "inherit", "enabled", "disabled"} {
				want := global
				if policy == "enabled" || role == model.ADMIN {
					want = true
				} else if policy == "disabled" {
					want = false
				}
				got := resolveFileDownloadEnabled(user, &model.Meta{DownloadPolicy: policy}, global)
				if got != want {
					t.Errorf("role=%d global=%t policy=%q: got %t, want %t", role, global, policy, got, want)
				}
			}
		}
	}
	if resolveFileDownloadEnabled(nil, nil, false) {
		t.Fatal("anonymous context must not be treated as administrator")
	}
}

func TestAdminFileDownloadBypassesPolicyLookup(t *testing.T) {
	admin := &model.User{Role: model.ADMIN}
	enabled, err := FileDownloadEnabled(admin, "/any")
	if err != nil || !enabled || !DefaultFileDownloadEnabled(admin) {
		t.Fatalf("admin should remain enabled without a database: enabled=%v err=%v", enabled, err)
	}
}
