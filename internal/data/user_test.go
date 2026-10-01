package data

import (
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/leonelquinteros/gotext"
	"github.com/libtnb/sqlite"
	"github.com/pquerna/otp/totp"
	"gorm.io/gorm"

	"github.com/acepanel/panel/v3/internal/biz"
)

func newUserRepoForTest(t *testing.T) *userRepo {
	t.Helper()

	db, err := gorm.Open(sqlite.Open("file::memory:"), &gorm.Config{SkipDefaultTransaction: true})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&biz.User{}); err != nil {
		t.Fatal(err)
	}

	return &userRepo{t: gotext.NewLocale("", "en"), db: db}
}

func TestGenerateTwoFAUsesUsername(t *testing.T) {
	repo := newUserRepoForTest(t)
	user := &biz.User{Username: "alice_admin-1"}
	if err := repo.db.Create(user).Error; err != nil {
		t.Fatal(err)
	}

	img, rawURL, secret, err := repo.GenerateTwoFA(user.ID)
	if err != nil {
		t.Fatalf("GenerateTwoFA: %v", err)
	}
	if img == nil {
		t.Fatal("GenerateTwoFA returned no QR image")
	}

	parsedURL, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse otpauth URL: %v", err)
	}
	if parsedURL.Scheme != "otpauth" || parsedURL.Host != "totp" {
		t.Fatalf("unexpected otpauth URL: %q", rawURL)
	}
	if got, want := strings.TrimPrefix(parsedURL.Path, "/"), "AcePanel:"+user.Username; got != want {
		t.Fatalf("account label = %q, want %q", got, want)
	}
	if got := parsedURL.Query().Get("issuer"); got != "AcePanel" {
		t.Fatalf("issuer = %q, want AcePanel", got)
	}
	if got := parsedURL.Query().Get("secret"); got != secret || secret == "" {
		t.Fatalf("URL secret = %q, returned secret = %q", got, secret)
	}

	code, err := totp.GenerateCode(secret, time.Now())
	if err != nil {
		t.Fatalf("generate TOTP code: %v", err)
	}
	if !totp.Validate(code, secret) {
		t.Fatal("generated TOTP code should validate")
	}
}

func TestGenerateTwoFAForMissingUser(t *testing.T) {
	repo := newUserRepoForTest(t)
	if _, rawURL, secret, err := repo.GenerateTwoFA(123); err == nil {
		t.Fatalf("GenerateTwoFA for missing user succeeded: URL=%q secret=%q", rawURL, secret)
	}
}
