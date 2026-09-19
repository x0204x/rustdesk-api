package admin

import (
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lejianwen/rustdesk-api/v2/model"
	"github.com/lejianwen/rustdesk-api/v2/service"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// These tests use only per-test temporary SQLite files and synthetic credentials.
// Do not mark them parallel: the application service registry is package-global.
func logoutTestService(t *testing.T) *gorm.DB {
	t.Helper()
	oldService, oldDB := service.AllService, service.DB
	t.Cleanup(func() { service.AllService, service.DB = oldService, oldDB })
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "logout-test.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open temporary database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get database handle: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&model.UserToken{}); err != nil {
		t.Fatalf("create test schema: %v", err)
	}
	service.AllService = &service.Service{UserService: &service.UserService{}}
	service.DB = db
	return db
}

func invokeLogout(t *testing.T, user interface{}, token interface{}, setToken bool) (int, map[string]interface{}) {
	t.Helper()
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/admin/logout", nil)
	if user != nil {
		c.Set("curUser", user)
	}
	if setToken {
		c.Set("token", token)
	}
	(&Login{}).Logout(c)
	var body map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("non-JSON logout reply: %v", err)
	}
	return w.Code, body
}

func TestAdminWebLogoutRequiresAuthenticatedContext(t *testing.T) {
	logoutTestService(t)
	user := &model.User{}
	user.Id = 7
	cases := []struct {
		name     string
		user     interface{}
		token    interface{}
		setToken bool
	}{
		{"no_context", nil, nil, false},
		{"missing_user", nil, "test-token", true},
		{"invalid_user_type", "not-a-user", "test-token", true},
		{"zero_user_id", &model.User{}, "test-token", true},
		{"missing_token", user, nil, false},
		{"invalid_token_type", user, 123, true},
		{"empty_token", user, "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, body := invokeLogout(t, tc.user, tc.token, tc.setToken)
			if status != 401 || body["error"] != "Unauthorized" {
				t.Fatalf("expected unauthorized logout, status=%d", status)
			}
		})
	}
}

func TestAdminWebLogoutDeletesOnlyCurrentSession(t *testing.T) {
	db := logoutTestService(t)
	user := &model.User{}
	user.Id = 7
	for _, fixture := range []struct {
		uid   uint
		token string
	}{
		{7, "current-synthetic-token"}, {7, "other-synthetic-session"}, {8, "other-synthetic-user"},
	} {
		record := &model.UserToken{UserId: fixture.uid, Token: fixture.token, ExpiredAt: time.Now().Add(time.Hour).Unix()}
		if err := db.Create(record).Error; err != nil {
			t.Fatalf("create session fixture: %v", err)
		}
	}
	status, body := invokeLogout(t, user, "current-synthetic-token", true)
	if status != 200 || body["code"] != float64(0) {
		t.Fatalf("logout failed, status=%d", status)
	}
	var removed, retained int64
	if err := db.Model(&model.UserToken{}).Where("token = ?", "current-synthetic-token").Count(&removed).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&model.UserToken{}).Count(&retained).Error; err != nil {
		t.Fatal(err)
	}
	if removed != 0 || retained != 2 {
		t.Fatalf("incorrect revocation: removed-session rows=%d, retained=%d", removed, retained)
	}
}

func TestAdminWebLogoutDoesNotReportSuccessOnStorageFailure(t *testing.T) {
	db := logoutTestService(t)
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	if err := sqlDB.Close(); err != nil {
		t.Fatal(err)
	}
	user := &model.User{}
	user.Id = 7
	status, body := invokeLogout(t, user, "synthetic-token", true)
	if status != 500 || body["error"] != "Logout failed" || body["code"] != nil {
		t.Fatalf("storage failure falsely accepted: status=%d", status)
	}
}
