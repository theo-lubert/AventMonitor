package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"avent-webrtc-bridge/pkg/tuya"
)

// Our request signing is a copy of aventproxy's (see tuya.go). Check that both
// sign the same request identically, so an upstream change cannot drift silently.
func TestSignMatchesUpstream(t *testing.T) {
	var form url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		form = r.PostForm
		w.Write([]byte(`{"success":true,"result":{}}`))
	}))
	defer srv.Close()

	upstream := tuya.NewMobileSDKClient(signingKey, "sid123", appKey, "device123", chKey)
	upstream.BaseURL = srv.URL
	if _, err := upstream.Call("smartlife.m.user.info.get", "1.0", map[string]any{"gid": 42}); err != nil {
		t.Fatal(err)
	}
	if form == nil || form.Get("sign") == "" {
		t.Fatal("upstream request was not signed")
	}

	params := map[string]string{}
	for k := range form {
		if k != "sign" {
			params[k] = form.Get(k)
		}
	}
	if got, want := sign(params), form.Get("sign"); got != want {
		t.Errorf("sign = %s, upstream signed %s", got, want)
	}
}

func TestSignIgnoresUnsignedAndEmptyParams(t *testing.T) {
	base := map[string]string{"a": "action", "v": "1.0", "time": "1700000000"}
	want := sign(base)
	extra := map[string]string{"a": "action", "v": "1.0", "time": "1700000000", "gid": "42", "lat": ""}
	if got := sign(extra); got != want {
		t.Errorf("unsigned or empty params changed the signature")
	}
}

func TestSwap(t *testing.T) {
	in := "00000000111111112222222233333333"
	if got, want := swap(in), "11111111000000003333333322222222"; got != want {
		t.Errorf("swap = %s, want %s", got, want)
	}
	if got := swap("short"); got != "short" {
		t.Errorf("swap changed a non-MD5 string: %s", got)
	}
}

func TestSessionFromPrefersServerDomain(t *testing.T) {
	raw := json.RawMessage(`{"sid":"s","uid":"u","domain":{"mobileApiUrl":"https://a1.tuyaus.com"}}`)
	p := loginParams{Email: "me@example.com", APIHost: "a1.tuyaeu.com", DeviceID: "d", Country: "1"}
	s, err := sessionFrom(raw, p)
	if err != nil {
		t.Fatal(err)
	}
	if s.APIHost != tuya.NormalizeAPIHost("a1.tuyaus.com") {
		t.Errorf("APIHost = %q, want the server's domain", s.APIHost)
	}
	if s.Email != p.Email || s.DeviceID != "d" || s.Country != "1" || s.SID != "s" {
		t.Errorf("session lost login fields: %+v", s)
	}
}

func TestRTSPPathSurvivesURLParsing(t *testing.T) {
	if got := rtspPath(Camera{ID: "bf12ab34cd", Name: "Chambre d’enfant"}); got != "/bf12ab34cd" {
		t.Errorf("rtspPath = %q, want the plain id", got)
	}
	seen := map[string]bool{}
	for _, id := range []string{"bf12ab34cd", "a/b c", "é?#%", "", "cam-"} {
		path := rtspPath(Camera{ID: id})
		// The RTSP server looks cameras up by url.Parse(requestURL).Path.
		u, err := url.Parse("rtsp://127.0.0.1:38554" + path)
		if err != nil || u.Path != path {
			t.Errorf("id %q: path %q parses back as %q (%v)", id, path, u.Path, err)
		}
		if seen[path] {
			t.Errorf("id %q: path %q is not unique", id, path)
		}
		seen[path] = true
	}
}

func TestWithParamsRejectsBadJSON(t *testing.T) {
	_, err := withParams(json.RawMessage(`{`), func(p loginParams) (any, error) { return nil, nil })
	if err == nil {
		t.Error("expected an error for invalid params")
	}
}

func TestStr(t *testing.T) {
	if got := str(nil, "", 3, "x", "y"); got != "x" {
		t.Errorf("str = %q, want the first non-empty string", got)
	}
}

// fakeAPI answers every call with result and records the last request's form.
func fakeAPI(t *testing.T, result string) (*httptest.Server, *url.Values) {
	t.Helper()
	var form url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		form = r.PostForm
		w.Write([]byte(`{"success":true,"result":` + result + `}`))
	}))
	t.Cleanup(srv.Close)
	return srv, &form
}

func TestSetDPSPublishesToTheDevice(t *testing.T) {
	srv, form := fakeAPI(t, `true`)
	s := Session{SID: "sid", DeviceID: "phone"}
	c := s.client()
	c.baseURL = srv.URL
	dps := map[string]json.RawMessage{"138": json.RawMessage(`true`), "158": json.RawMessage(`30`)}
	if _, err := publishDPS(c, "cam", dps); err != nil {
		t.Fatal(err)
	}
	if got := form.Get("a"); got != "tuya.m.device.dp.publish" {
		t.Errorf("action = %q", got)
	}
	var post struct {
		DevID string         `json:"devId"`
		GwID  string         `json:"gwId"`
		DPS   map[string]any `json:"dps"`
	}
	if err := json.Unmarshal([]byte(form.Get("postData")), &post); err != nil {
		t.Fatal(err)
	}
	if post.DevID != "cam" || post.GwID != "cam" || post.DPS["138"] != true || post.DPS["158"] != float64(30) {
		t.Errorf("postData = %s", form.Get("postData"))
	}
}

func TestSetDPSRejectsEmptyCommands(t *testing.T) {
	if _, err := setDPS(setDPSParams{ID: "cam"}); err == nil {
		t.Error("expected an error without data points")
	}
	if _, err := setDPS(setDPSParams{DPS: map[string]json.RawMessage{"138": json.RawMessage(`true`)}}); err == nil {
		t.Error("expected an error without a device id")
	}
}

func TestReadDeviceReturnsDataPoints(t *testing.T) {
	srv, form := fakeAPI(t, `{"isOnline":true,"dps":{"138":false,"207":2150,"248":"{\"id\":3542155}"}}`)
	c := (Session{SID: "sid"}).client()
	c.baseURL = srv.URL
	st, err := readDevice(c, "cam")
	if err != nil {
		t.Fatal(err)
	}
	if form.Get("a") != "tuya.m.device.get" {
		t.Errorf("action = %q, want a read", form.Get("a"))
	}
	if !st.Online || string(st.DPS["138"]) != "false" || string(st.DPS["207"]) != "2150" {
		t.Errorf("state = %+v", st)
	}
}
