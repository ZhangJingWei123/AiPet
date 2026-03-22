package auth

import (
	"context"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/golang-jwt/jwt/v5"
)

var (
    ErrMissingAuthHeader = errors.New("缺少 Authorization 头")
    ErrInvalidToken      = errors.New("无效的 Token")
)

// Claims 自定义 JWT Claims
type Claims struct {
    UserID uint   `json:"user_id"`
    AppleID string `json:"apple_id,omitempty"`
    PhoneNumber string `json:"phone_number,omitempty"`
    jwt.RegisteredClaims
}

// GenerateToken 生成 Access Token
func GenerateToken(secret string, userID uint, appleID, phone string, ttl time.Duration) (string, error) {
    if secret == "" {
        secret = os.Getenv("JWT_SECRET")
    }
    if secret == "" {
        return "", errors.New("JWT_SECRET 未配置")
    }

    now := time.Now()
    claims := Claims{
        UserID:      userID,
        AppleID:     appleID,
        PhoneNumber: phone,
        RegisteredClaims: jwt.RegisteredClaims{
            IssuedAt:  jwt.NewNumericDate(now),
            ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
        },
    }

    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    return token.SignedString([]byte(secret))
}

// ParseToken 解析并验证 Token
func ParseToken(secret, tokenStr string) (*Claims, error) {
    if secret == "" {
        secret = os.Getenv("JWT_SECRET")
    }
    if secret == "" {
        return nil, errors.New("JWT_SECRET 未配置")
    }

    token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(token *jwt.Token) (interface{}, error) {
        if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
            return nil, ErrInvalidToken
        }
        return []byte(secret), nil
    })
    if err != nil {
        return nil, err
    }

    claims, ok := token.Claims.(*Claims)
    if !ok || !token.Valid {
        return nil, ErrInvalidToken
    }

    return claims, nil
}

// AuthMiddleware 示例中间件，验证 Authorization: Bearer <token>
func AuthMiddleware(secret string) app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        authHeader := string(c.Request.Header.Peek("Authorization"))
        if authHeader == "" {
            c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": ErrMissingAuthHeader.Error()})
            return
        }

        parts := strings.SplitN(authHeader, " ", 2)
        if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
            c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": ErrInvalidToken.Error()})
            return
        }

        claims, err := ParseToken(secret, parts[1])
        if err != nil {
            c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": ErrInvalidToken.Error()})
            return
        }

        c.Set("authClaims", claims)
        c.Next(ctx)
    }
}
