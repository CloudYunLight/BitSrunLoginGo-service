package srun

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSearchAcidInPage(t *testing.T) {
	tests := []struct {
		name string
		page string
		want string
	}{
		{name: "隐藏表单标准顺序", page: `<input name="ac_id" value="8">`, want: "8"},
		{name: "隐藏表单反向顺序", page: `<input value='12' id='ac_id' type='hidden'>`, want: "12"},
		{name: "JavaScript 对象", page: `<script>const portal = {"ac_id": "17"};</script>`, want: "17"},
		{name: "链接参数", page: `<a href="/index.html?foo=1&ac_id=23&bar=2">登录</a>`, want: "23"},
		{name: "HTML 转义链接参数", page: `<a href="/index.html?foo=1&amp;ac_id=29">登录</a>`, want: "29"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := searchAcidInPage([]byte(tt.page))
			if !ok || got != tt.want {
				t.Fatalf("searchAcidInPage() = %q, %v; want %q, true", got, ok, tt.want)
			}
		})
	}
}

func TestDetectAcidFromDirectPortalPage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`<html><input value="8" name="ac_id"></html>`))
	}))
	defer server.Close()

	api := Api{}
	api.Init(&ApiConfig{
		Domain: strings.TrimPrefix(server.URL, "http://"),
		Client: server.Client(),
	})

	acid, err := api.NewDetector().DetectAcid()
	if err != nil {
		t.Fatal(err)
	}
	if acid != "8" {
		t.Fatalf("DetectAcid() = %q; want 8", acid)
	}
}

func TestDetectAcidFromFinalURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/portal?ac_id=31", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte("portal"))
	}))
	defer server.Close()

	api := Api{}
	api.Init(&ApiConfig{
		Domain: strings.TrimPrefix(server.URL, "http://"),
		Client: server.Client(),
	})

	acid, err := api.NewDetector().DetectAcid()
	if err != nil {
		t.Fatal(err)
	}
	if acid != "31" {
		t.Fatalf("DetectAcid() = %q; want 31", acid)
	}
}
