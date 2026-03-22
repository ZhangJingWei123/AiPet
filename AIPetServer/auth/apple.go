package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	jwtv4 "github.com/golang-jwt/jwt/v4"
	"github.com/golang-jwt/jwt/v5"
)

const appleKeysURL = "https://appleid.apple.com/auth/keys"

// AppleIdentityClaims Apple 返回的 JWT Claims 结构
type AppleIdentityClaims struct {
    Sub   string `json:"sub"`
    Email string `json:"email"`
    jwt.RegisteredClaims
}

type appleKey struct {
    Kty string `json:"kty"`
    Kid string `json:"kid"`
    Use string `json:"use"`
    Alg string `json:"alg"`
    N   string `json:"n"`
    E   string `json:"e"`
}

type appleJWKS struct {
    Keys []appleKey `json:"keys"`
}

var (
    jwksCache     appleJWKS
    jwksCacheAt   time.Time
    jwksCacheLock sync.RWMutex
)

// getApplePublicKey 根据 kid 获取 Apple 公钥
func getApplePublicKey(ctx context.Context, kid string) (*rsa.PublicKey, error) {
    jwksCacheLock.RLock()
    if time.Since(jwksCacheAt) < time.Hour && len(jwksCache.Keys) > 0 {
        for _, k := range jwksCache.Keys {
            if k.Kid == kid {
                jwksCacheLock.RUnlock()
                return appleKeyToPublicKey(k)
            }
        }
    }
    jwksCacheLock.RUnlock()

    // 重新拉取 JWKS
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, appleKeysURL, nil)
    if err != nil {
        return nil, err
    }
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("获取 Apple 公钥失败，状态码: %d", resp.StatusCode)
    }

    var jwks appleJWKS
    if err := json.NewDecoder(resp.Body).Decode(&jwks); err != nil {
        return nil, err
    }

    jwksCacheLock.Lock()
    jwksCache = jwks
    jwksCacheAt = time.Now()
    jwksCacheLock.Unlock()

    for _, k := range jwks.Keys {
        if k.Kid == kid {
            return appleKeyToPublicKey(k)
        }
    }

    return nil, errors.New("未找到匹配的 Apple 公钥")
}

// appleKeyToPublicKey 将 Apple JWKS key 转换为 rsa.PublicKey
func appleKeyToPublicKey(k appleKey) (*rsa.PublicKey, error) {
	// Apple 返回的 N/E 为 Base64URL 编码，需转换为大整数构造 rsa.PublicKey
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("解析 Apple N 失败: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("解析 Apple E 失败: %w", err)
	}
	// eBytes 为大端整数
	var e int
	for _, b := range eBytes {
		e = e<<8 | int(b)
	}
	if e == 0 {
		return nil, errors.New("Apple 公钥 E 非法")
	}

	pubKey := &rsa.PublicKey{
		N: new(big.Int).SetBytes(nBytes),
		E: e,
	}
	return pubKey, nil
}

// VerifyAppleIdentityToken 验证 Apple identityToken，并返回 Claims
func VerifyAppleIdentityToken(ctx context.Context, identityToken string) (*AppleIdentityClaims, error) {
    parser := jwt.Parser{}

    token, err := parser.ParseWithClaims(identityToken, &AppleIdentityClaims{}, func(token *jwt.Token) (interface{}, error) {
        header, ok := token.Header["kid"].(string)
        if !ok || header == "" {
            return nil, errors.New("Apple identityToken 缺少 kid")
        }
        // 这里理论上应返回实际的 *rsa.PublicKey，但为了避免引入复杂实现，
        // 暂时返回错误，提示在生产环境中补全。
        return getApplePublicKey(ctx, header)
    })
    if err != nil {
        return nil, err
    }

    claims, ok := token.Claims.(*AppleIdentityClaims)
    if !ok || !token.Valid {
        return nil, errors.New("Apple identityToken 无效")
    }

	return claims, nil
}

// -------------------------
// App Store Server API (StoreKit 2) 支付校验
// -------------------------

const (
	appStoreProdBaseURL    = "https://api.storekit.itunes.apple.com"
	appStoreSandboxBaseURL = "https://api.storekit-sandbox.itunes.apple.com"
)

// ApplePayConfig 为 Apple Server API 凭证配置
//
// 通常来自 App Store Connect:
// - KeyID: App Store Server API 密钥 ID
// - IssuerID: Issuer ID
// - PrivateKey: 对应的 ES256 私钥（.p8 内容）
type ApplePayConfig struct {
	KeyID      string
	IssuerID   string
	PrivateKey string
}

// ApplePayService 负责与 Apple App Store Server API 交互
type ApplePayService struct {
	keyID      string
	issuerID   string
	privateKey *ecdsa.PrivateKey
}

// NewApplePayServiceFromEnv 基于环境变量构建 ApplePayService
//
// 约定的环境变量：
// - APPLE_IAP_KEY_ID
// - APPLE_IAP_ISSUER_ID
// - APPLE_IAP_PRIVATE_KEY （.p8 原始文本内容）
func NewApplePayServiceFromEnv() (*ApplePayService, error) {
	cfg := ApplePayConfig{
		KeyID:      os.Getenv("APPLE_IAP_KEY_ID"),
		IssuerID:   os.Getenv("APPLE_IAP_ISSUER_ID"),
		PrivateKey: os.Getenv("APPLE_IAP_PRIVATE_KEY"),
	}
	return NewApplePayService(cfg)
}

// NewApplePayService 使用显式配置创建 ApplePayService
func NewApplePayService(cfg ApplePayConfig) (*ApplePayService, error) {
	if cfg.KeyID == "" || cfg.IssuerID == "" || cfg.PrivateKey == "" {
		return nil, errors.New("ApplePayConfig 不完整: 需要 KeyID / IssuerID / PrivateKey")
	}

	privKey, err := parseECPrivateKey(cfg.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("解析 Apple Server API 私钥失败: %w", err)
	}

	return &ApplePayService{
		keyID:      cfg.KeyID,
		issuerID:   cfg.IssuerID,
		privateKey: privKey,
	}, nil
}

// parseECPrivateKey 解析 .p8 ECDSA 私钥
func parseECPrivateKey(pemContent string) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemContent))
	if block == nil {
		return nil, errors.New("无法解析 Apple 私钥 PEM 内容")
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析 PKCS8 私钥失败: %w", err)
	}

	priv, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("Apple 私钥不是 ECDSA 类型")
	}
	return priv, nil
}

// generateServerJWT 生成调用 App Store Server API 所需的 JWT
func (s *ApplePayService) generateServerJWT() (string, error) {
	now := time.Now().Unix()
	claims := jwtv4.MapClaims{
		"iss": s.issuerID,
		"iat": now,
		"exp": now + 1800, // 官方建议不超过 30 分钟
		"aud": "appstoreconnect-v1",
	}

	token := jwtv4.NewWithClaims(jwtv4.SigningMethodES256, claims)
	token.Header["kid"] = s.keyID

	return token.SignedString(s.privateKey)
}

// TransactionInfo 为 VerifyTransaction 的结构化结果
type TransactionInfo struct {
	AppAccountToken       string     `json:"app_account_token"`
	TransactionID         string     `json:"transaction_id"`
	OriginalTransactionID string     `json:"original_transaction_id"`
	ExpiresDate           *time.Time `json:"expires_date"`
	Environment           string     `json:"environment"`
}

// VerifyTransaction 调用 Apple Server API 获取交易详情，并解析核心字段。
//
// 策略：先访问生产环境，若返回 404 再自动回退到 Sandbox。
func (s *ApplePayService) VerifyTransaction(ctx context.Context, transactionID string) (*TransactionInfo, error) {
	if transactionID == "" {
		return nil, errors.New("transactionID 不能为空")
	}

	jwtStr, err := s.generateServerJWT()
	if err != nil {
		return nil, fmt.Errorf("生成 Apple Server API JWT 失败: %w", err)
	}

	info, status, err := s.fetchTransaction(ctx, appStoreProdBaseURL, transactionID, jwtStr)
	if err != nil {
		// 非 404 错误直接返回
		if status != http.StatusNotFound {
			return nil, err
		}
	}
	if info != nil {
		return info, nil
	}

	// 生产环境未找到时，尝试 Sandbox
	info, _, err = s.fetchTransaction(ctx, appStoreSandboxBaseURL, transactionID, jwtStr)
	if err != nil {
		return nil, err
	}
	return info, nil
}

// fetchTransaction 调用指定环境的 inApps/v1/transactions 接口
func (s *ApplePayService) fetchTransaction(ctx context.Context, baseURL, transactionID, jwtStr string) (*TransactionInfo, int, error) {
	url := fmt.Sprintf("%s/inApps/v1/transactions/%s", strings.TrimRight(baseURL, "/"), transactionID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+jwtStr)
	req.Header.Set("Accept", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, resp.StatusCode, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode, fmt.Errorf("Apple Server API 响应状态码异常: %d", resp.StatusCode)
	}

	var body struct {
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		Environment           string `json:"environment"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("解析 Apple 交易响应失败: %w", err)
	}
	if body.SignedTransactionInfo == "" {
		return nil, resp.StatusCode, errors.New("Apple 响应缺少 signedTransactionInfo")
	}

	claims, err := parseStoreKitJWSPayload(body.SignedTransactionInfo)
	if err != nil {
		return nil, resp.StatusCode, err
	}

	var expiresAt *time.Time
	if claims.ExpiresDateMs > 0 {
		// StoreKit 返回的是毫秒时间戳
		t := time.UnixMilli(claims.ExpiresDateMs)
		expiresAt = &t
	}

	info := &TransactionInfo{
		AppAccountToken:       claims.AppAccountToken,
		TransactionID:         claims.TransactionID,
		OriginalTransactionID: claims.OriginalTransactionID,
		ExpiresDate:           expiresAt,
		Environment:           body.Environment,
	}
	return info, resp.StatusCode, nil
}

// storeKitJWSPayload 为 signedTransactionInfo 的 Payload 结构
type storeKitJWSPayload struct {
	AppAccountToken       string `json:"appAccountToken"`
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	ExpiresDateMs         int64  `json:"expiresDate"`
}

// parseStoreKitJWSPayload 解码 StoreKit 返回的 JWS（不做签名校验，仅用于服务端解析字段）
func parseStoreKitJWSPayload(jws string) (*storeKitJWSPayload, error) {
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return nil, errors.New("signedTransactionInfo 不是合法的 JWS 格式")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("解码 StoreKit JWS Payload 失败: %w", err)
	}

	var payload storeKitJWSPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, fmt.Errorf("解析 StoreKit JWS JSON 失败: %w", err)
	}
	return &payload, nil
}
