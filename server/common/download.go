package common

import (
	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/OpenListTeam/OpenList/v4/internal/setting"
)

// FileDownloadEnabled controls download/copy-link/QR UI entries only. It does
// not change content access or streaming, which are also needed for previews.
func FileDownloadEnabled(user *model.User, folderPath string) (bool, error) {
	if user != nil && user.IsAdmin() {
		return true, nil
	}
	meta, err := op.GetFileDownloadMeta(folderPath)
	if err != nil {
		return false, err
	}
	return resolveFileDownloadEnabled(user, meta, DefaultFileDownloadEnabled(user)), nil
}

func DefaultFileDownloadEnabled(user *model.User) bool {
	if user != nil && user.IsAdmin() {
		return true
	}
	value := setting.GetStr(conf.EnableFileDownload, "true")
	return resolveFileDownloadEnabled(user, nil, value != "false" && value != "0")
}

func resolveFileDownloadEnabled(user *model.User, meta *model.Meta, defaultEnabled bool) bool {
	if user != nil && user.IsAdmin() {
		return true
	}
	if meta != nil {
		switch meta.DownloadPolicy {
		case model.DownloadPolicyEnabled:
			return true
		case model.DownloadPolicyDisabled:
			return false
		}
	}
	return defaultEnabled
}
