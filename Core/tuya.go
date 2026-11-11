package main

// Mobile SDK calls used for login and device discovery. The request signing
// mirrors avent-webrtc-bridge/pkg/tuya/mobile_api.go (MIT, thekoma/aventproxy);
// it is repeated here because that client cannot send the unsigned form
// parameters (gid) that device discovery needs.

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"avent-webrtc-bridge/pkg/tuya"

	"github.com/google/uuid"
)

const (
	chKey       = "071d81fa"
	appVersion  = "1.8.0"
	sdkVersion  = "6.7.0"
	packageName = "com.philips.ph.babymonitorplus"
)

var signWhitelist = map[string]bool{
	"a": true, "v": true, "lat": true, "lon": true, "lang": true, "deviceId": true,
	"appVersion": true, "ttid": true, "isH5": true, "h5Token": true, "os": true,
	"clientId": true, "postData": true, "time": true, "requestId": true, "et": true,
	"n4h5": true, "sid": true, "chKey": true, "sp": true,
}

// APIError carries Tuya's machine-readable error code to Swift.
type APIError struct {
	Code    string
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("%s (%s)", e.Message, e.Code) }

type client struct {
	host     string
	sid      string
	deviceID string
}

func swap(s string) string {
	if len(s) != 32 {
		return s
	}
	return s[8:16] + s[0:8] + s[24:32] + s[16:24]
}

func sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	filtered := map[string]string{}
	for k, v := range params {
		if signWhitelist[k] && v != "" {
			filtered[k] = v
			keys = append(keys, k)
		}
	}
	if pd := filtered["postData"]; pd != "" {
		h := md5.Sum([]byte(pd))
		filtered["postData"] = swap(hex.EncodeToString(h[:]))
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + filtered[k]
	}
	mac := hmac.New(sha256.New, []byte(signingKey))
	mac.Write([]byte(strings.Join(parts, "||")))
	return hex.EncodeToString(mac.Sum(nil))
}

func (c *client) call(action, version string, postData any, extra map[string]string) (json.RawMessage, error) {
	params := map[string]string{
		"a": action, "v": version, "time": fmt.Sprintf("%d", time.Now().Unix()),
		"appVersion": appVersion, "appRnVersion": "5.92", "channel": "oem", "chKey": chKey,
		"clientId": appKey, "cp": "gzip", "deviceCoreVersion": sdkVersion, "deviceId": c.deviceID,
		"et": "0.0.1", "nd": "1", "lang": "fr_FR", "os": "Android", "osSystem": "14",
		"platform": "tuya_bridge", "requestId": uuid.New().String(), "sdkVersion": sdkVersion,
		"sid": c.sid, "timeZoneId": "Europe/Paris", "ttid": "sdk_international@" + appKey,
	}
	if postData != nil {
		b, err := json.Marshal(postData)
		if err != nil {
			return nil, err
		}
		params["postData"] = string(b)
	}
	params["sign"] = sign(params)
	form := url.Values{}
	for k, v := range params {
		form.Set(k, v)
	}
	for k, v := range extra { // unsigned, as in the HA integration
		form.Set(k, v)
	}
	req, err := http.NewRequest("POST", tuya.APIBaseURL(c.host), strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", fmt.Sprintf("Thing-UA=APP/Android/%s/SDK/%s", appVersion, sdkVersion))
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var r struct {
		Result    json.RawMessage `json:"result"`
		Success   bool            `json:"success"`
		ErrorCode string          `json:"errorCode"`
		ErrorMsg  string          `json:"errorMsg"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, fmt.Errorf("invalid response from %s", c.host)
	}
	if !r.Success {
		return nil, &APIError{Code: r.ErrorCode, Message: r.ErrorMsg}
	}
	return r.Result, nil
}

func (c *client) encryptedPassword(email, password, country string) (string, string, error) {
	raw, err := c.call("thing.m.user.username.token.get", "2.0",
		map[string]any{"countryCode": country, "username": email, "isUid": false}, nil)
	if err != nil {
		return "", "", err
	}
	var tok struct {
		Token string `json:"token"`
		PbKey string `json:"pbKey"`
	}
	if err := json.Unmarshal(raw, &tok); err != nil {
		return "", "", err
	}
	block, _ := pem.Decode([]byte("-----BEGIN PUBLIC KEY-----\n" + tok.PbKey + "\n-----END PUBLIC KEY-----"))
	if block == nil {
		return "", "", fmt.Errorf("invalid RSA key from server")
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return "", "", err
	}
	rsaKey, ok := pub.(*rsa.PublicKey)
	if !ok {
		return "", "", fmt.Errorf("unexpected key type")
	}
	sum := md5.Sum([]byte(password))
	enc, err := rsa.EncryptPKCS1v15(rand.Reader, rsaKey, []byte(hex.EncodeToString(sum[:])))
	if err != nil {
		return "", "", err
	}
	return hex.EncodeToString(enc), tok.Token, nil
}

// Session is what Swift keeps in the Keychain.
type Session struct {
	SID      string `json:"sid"`
	Ecode    string `json:"ecode"`
	Partner  string `json:"partner"`
	UID      string `json:"uid"`
	Email    string `json:"email"`
	Nickname string `json:"nickname"`
	APIHost  string `json:"apiHost"`
	DeviceID string `json:"deviceId"`
	Country  string `json:"country"`
}

type loginParams struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Country  string `json:"country"`
	Code     string `json:"code"`
	APIHost  string `json:"apiHost"`
	DeviceID string `json:"deviceId"`
}

func (p loginParams) client() *client {
	return &client{host: tuya.NormalizeAPIHost(p.APIHost), deviceID: p.DeviceID}
}

func login(p loginParams, mfa string) (json.RawMessage, error) {
	c := p.client()
	enc, token, err := c.encryptedPassword(p.Email, p.Password, p.Country)
	if err != nil {
		return nil, err
	}
	opts, _ := json.Marshal(map[string]any{"group": 1, "mfaCode": mfa})
	return c.call("thing.m.user.email.password.login", "3.0", map[string]any{
		"countryCode": p.Country, "email": p.Email, "passwd": enc, "token": token,
		"ifencrypt": 1, "options": string(opts),
	}, nil)
}

// sendCode asks Tuya to email a verification code. When the account needs no
// code, it returns the session straight away.
func sendCode(p loginParams) (any, error) {
	raw, err := login(p, "")
	if err == nil {
		s, err := sessionFrom(raw, p)
		return map[string]any{"session": s}, err
	}
	if ae, ok := err.(*APIError); !ok || ae.Code != "MFA_NEED_SEND_CODE" {
		return nil, err
	}
	c := p.client()
	enc, token, err := c.encryptedPassword(p.Email, p.Password, p.Country)
	if err != nil {
		return nil, err
	}
	if _, err := c.call("thing.m.user.username.mfa.code.get", "1.0", map[string]any{
		"countryCode": p.Country, "username": p.Email, "passwd": enc, "token": token,
		"ifencrypt": 1, "options": `{"group":1,"mfaCode":"null"}`,
	}, nil); err != nil {
		return nil, err
	}
	return map[string]any{"codeSent": true}, nil
}

func verify(p loginParams) (any, error) {
	raw, err := login(p, strings.TrimSpace(p.Code))
	if err != nil {
		return nil, err
	}
	s, err := sessionFrom(raw, p)
	return map[string]any{"session": s}, err
}

func sessionFrom(raw json.RawMessage, p loginParams) (*Session, error) {
	var r struct {
		SID      string `json:"sid"`
		Ecode    string `json:"ecode"`
		Partner  string `json:"partnerIdentity"`
		UID      string `json:"uid"`
		Email    string `json:"email"`
		Nickname string `json:"nickname"`
		Domain   struct {
			MobileAPIURL string `json:"mobileApiUrl"`
		} `json:"domain"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, err
	}
	host := tuya.NormalizeAPIHost(p.APIHost)
	if r.Domain.MobileAPIURL != "" {
		host = tuya.NormalizeAPIHost(r.Domain.MobileAPIURL)
	}
	email := r.Email
	if email == "" {
		email = p.Email
	}
	return &Session{SID: r.SID, Ecode: r.Ecode, Partner: r.Partner, UID: r.UID, Email: email,
		Nickname: r.Nickname, APIHost: host, DeviceID: p.DeviceID, Country: p.Country}, nil
}

func (s Session) client() *client {
	return &client{host: tuya.NormalizeAPIHost(s.APIHost), sid: s.SID, deviceID: s.DeviceID}
}

func userInfo(s Session) (any, error) {
	raw, err := s.client().call("smartlife.m.user.info.get", "1.0", nil, nil)
	if err != nil {
		return nil, err
	}
	var u struct {
		ID       string `json:"id"`
		Email    string `json:"email"`
		Nickname string `json:"nickname"`
	}
	if err := json.Unmarshal(raw, &u); err != nil {
		return nil, err
	}
	return u, nil
}

// Camera is one monitor on the account.
type Camera struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	ProductID string `json:"productId"`
	Category  string `json:"category"`
	Online    bool   `json:"online"`
}

// listCameras mirrors the HA integration's discovery strategies.
func listCameras(s Session) ([]Camera, error) {
	c := s.client()
	raw, err := c.call("m.life.home.space.list", "1.0", nil, nil)
	if err != nil {
		return nil, err
	}
	var homes []struct {
		Gid json.Number `json:"gid"`
	}
	_ = json.Unmarshal(raw, &homes)

	seen := map[string]bool{}
	var cams []Camera
	add := func(raw json.RawMessage) {
		var devs []map[string]any
		if json.Unmarshal(raw, &devs) != nil {
			return
		}
		for _, d := range devs {
			id := str(d["devId"], d["deviceId"], d["id"])
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			online, _ := d["isOnline"].(bool)
			cams = append(cams, Camera{ID: id, Name: str(d["name"], d["deviceName"]),
				ProductID: str(d["productId"]), Category: str(d["category"]), Online: online})
		}
	}
	for _, h := range homes {
		gid := h.Gid.String()
		if gid == "" {
			continue
		}
		for _, v := range []string{"2.0", "1.0"} {
			if r, err := c.call("tuya.m.location.get", v, map[string]string{"gid": gid}, map[string]string{"gid": gid}); err == nil {
				var rooms []struct {
					DeviceList json.RawMessage `json:"deviceList"`
				}
				if json.Unmarshal(r, &rooms) == nil {
					for _, room := range rooms {
						add(room.DeviceList)
					}
				}
			}
			if len(cams) > 0 {
				break
			}
		}
		if len(cams) == 0 {
			if r, err := c.call("tuya.m.my.group.device.list", "1.0", nil, map[string]string{"gid": gid}); err == nil {
				add(r)
			}
		}
		if len(cams) == 0 {
			if r, err := c.call("tuya.m.my.group.device.relation.list", "1.0", nil, map[string]string{"gid": gid}); err == nil {
				add(r)
			}
		}
	}
	if len(cams) == 0 {
		if r, err := c.call("tuya.m.device.list.get", "1.0", nil, nil); err == nil {
			add(r)
		}
	}
	// Refresh online state from the device itself when the list omits it.
	for i := range cams {
		if r, err := c.call("tuya.m.device.get", "1.0", map[string]string{"devId": cams[i].ID}, nil); err == nil {
			var d struct {
				IsOnline  bool   `json:"isOnline"`
				ProductID string `json:"productId"`
			}
			if json.Unmarshal(r, &d) == nil {
				cams[i].Online = d.IsOnline
				if cams[i].ProductID == "" {
					cams[i].ProductID = d.ProductID
				}
			}
		}
	}
	return cams, nil
}

func str(vals ...any) string {
	for _, v := range vals {
		if s, ok := v.(string); ok && s != "" {
			return s
		}
	}
	return ""
}
