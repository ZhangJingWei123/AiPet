package handlers

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"gorm.io/gorm"

	"AIPetServer/auth"
	"AIPetServer/models"
)

// RegisterMembershipRoutes 注册会员相关路由
func RegisterMembershipRoutes(h *server.Hertz, jwtSecret string) {
	g := h.Group("/v1/membership")
	g.Use(auth.AuthMiddleware(jwtSecret))

	g.GET("/status", MembershipStatusHandler())
	g.POST("/mock_upgrade_plus", MockUpgradePlusHandler())
}

// RegisterAppleWebhookRoutes 注册 Apple Server Notification V2 Webhook
//
// 该端点无需用户登录，由 Apple 服务端直接调用。
func RegisterAppleWebhookRoutes(h *server.Hertz) {
	h.POST("/v1/webhook/apple", AppleNotificationV2Handler())
}

// MembershipStatusHandler 查询并自动校正会员状态
func MembershipStatusHandler() app.HandlerFunc {
	type response struct {
		IsPlusMember  bool       `json:"is_plus_member"`
		PlusExpiresAt *time.Time `json:"plus_expires_at"`
		IsPlusActive  bool       `json:"is_plus_active"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		claimsVal, ok := c.Get("authClaims")
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "未认证"})
			return
		}
		claims, ok := claimsVal.(*auth.Claims)
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "认证信息错误"})
			return
		}

		var user models.User
		if err := db.First(&user, claims.UserID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				c.JSON(http.StatusUnauthorized, map[string]string{"error": "用户不存在"})
				return
			}
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询用户失败"})
			return
		}

		now := time.Now()
		// 如果已过期则自动纠正会员状态
		if user.IsPlusMember && user.PlusExpiresAt != nil && !user.PlusExpiresAt.After(now) {
			user.IsPlusMember = false
			user.PlusExpiresAt = nil
			_ = db.Model(&user).Updates(map[string]interface{}{
				"is_plus_member":   user.IsPlusMember,
				"plus_expires_at": user.PlusExpiresAt,
			}).Error
		}

		active := user.IsPlusActive(now)
		c.JSON(http.StatusOK, response{
			IsPlusMember:  user.IsPlusMember,
			PlusExpiresAt: user.PlusExpiresAt,
			IsPlusActive:  active,
		})
	}
}

// MockUpgradePlusHandler 模拟订阅成功后的会员升级
func MockUpgradePlusHandler() app.HandlerFunc {
	type request struct {
		DurationDays int `json:"duration_days"`
	}

	type response struct {
		Success       bool       `json:"success"`
		IsPlusMember  bool       `json:"is_plus_member"`
		PlusExpiresAt *time.Time `json:"plus_expires_at"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		var req request
		if err := c.BindAndValidate(&req); err != nil {
			// duration_days 可选，因此这里只检查 JSON 格式
			req.DurationDays = 0
		}
		if req.DurationDays <= 0 {
			req.DurationDays = 30
		}

		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		claimsVal, ok := c.Get("authClaims")
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "未认证"})
			return
		}
		claims, ok := claimsVal.(*auth.Claims)
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "认证信息错误"})
			return
		}

		var user models.User
		if err := db.First(&user, claims.UserID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				c.JSON(http.StatusUnauthorized, map[string]string{"error": "用户不存在"})
				return
			}
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询用户失败"})
			return
		}

		now := time.Now()
		start := now
		if user.IsPlusActive(now) && user.PlusExpiresAt != nil {
			start = *user.PlusExpiresAt
		}
		newExpire := start.Add(time.Duration(req.DurationDays) * 24 * time.Hour)

		user.IsPlusMember = true
		user.PlusExpiresAt = &newExpire
		if err := db.Model(&user).Updates(map[string]interface{}{
			"is_plus_member":   user.IsPlusMember,
			"plus_expires_at": user.PlusExpiresAt,
		}).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "更新会员状态失败"})
			return
		}

		c.JSON(http.StatusOK, response{
			Success:       true,
			IsPlusMember:  user.IsPlusMember,
			PlusExpiresAt: user.PlusExpiresAt,
		})

		// 业务埋点：Mock 升级 Plus
		if db != nil {
			recordEvent(ctx, db, &user.ID, "mock_plus_purchase", getClientPlatform(c), map[string]interface{}{
				"duration_days": req.DurationDays,
			})
		}
	}
}

// AppleNotificationV2Handler 处理 Apple StoreKit 2 Notification V2 推送
//
// 仅处理 SUBSCRIBED / DID_RENEW 事件，用于更新订单与会员状态。
func AppleNotificationV2Handler() app.HandlerFunc {
	type request struct {
		SignedPayload string `json:"signedPayload" binding:"required"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		var req request
		if err := c.BindAndValidate(&req); err != nil {
			c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid signedPayload"})
			return
		}

		// 从上下文获取 DB
		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		payload, err := decodeAppleNotificationPayload(req.SignedPayload)
		if err != nil {
			c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		// 只关心订阅创建和续订两类事件
		if payload.NotificationType != "SUBSCRIBED" && payload.NotificationType != "DID_RENEW" {
			c.JSON(http.StatusOK, map[string]string{"status": "ignored"})
			return
		}

		// 解析交易信息
		if payload.Data.SignedTransactionInfo == "" {
			c.JSON(http.StatusBadRequest, map[string]string{"error": "missing signedTransactionInfo"})
			return
		}

		claims, err := parseStoreKitJWSPayload(payload.Data.SignedTransactionInfo)
		if err != nil {
			c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		// 计算到期时间
		var expiresAt *time.Time
		if claims.ExpiresDateMs > 0 {
			t := time.UnixMilli(claims.ExpiresDateMs)
			expiresAt = &t
		}

		// 尝试从 appAccountToken 解析 UserID（约定前端以用户 ID 作为 appAccountToken）
		var userID uint
		if claims.AppAccountToken != "" {
			if n, err := strconv.ParseUint(claims.AppAccountToken, 10, 64); err == nil {
				userID = uint(n)
			}
		}

		// 先 upsert 订单记录
		var order models.Order
		if err := db.Where("original_transaction_id = ?", claims.OriginalTransactionID).
			First(&order).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				order = models.Order{
					UserID:               userID,
					AppAccountToken:      claims.AppAccountToken,
					TransactionID:        claims.TransactionID,
					OriginalTransactionID: claims.OriginalTransactionID,
					Status:               models.OrderStatusCompleted,
					ExpiresDate:          expiresAt,
					Environment:          payload.Data.Environment,
				}
				if err := db.Create(&order).Error; err != nil {
					c.JSON(http.StatusInternalServerError, map[string]string{"error": "保存订单失败"})
					return
				}
			} else {
				c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询订单失败"})
				return
			}
		} else {
			updates := map[string]interface{}{
				"status":      models.OrderStatusCompleted,
				"expires_date": expiresAt,
			}
			_ = db.Model(&order).Updates(updates).Error
			if userID == 0 && order.UserID != 0 {
				userID = order.UserID
			}
		}

		// 更新用户会员状态
		if userID != 0 && expiresAt != nil {
			var user models.User
			if err := db.First(&user, userID).Error; err == nil {
				// 若用户当前仍在有效期内，则延长；否则从当前交易的到期时间起算
				newExpire := *expiresAt
				if user.PlusExpiresAt != nil && user.PlusExpiresAt.After(newExpire) {
					newExpire = *user.PlusExpiresAt
				}
				user.IsPlusMember = true
				user.PlusExpiresAt = &newExpire
				_ = db.Model(&user).Updates(map[string]interface{}{
					"is_plus_member":   user.IsPlusMember,
					"plus_expires_at": user.PlusExpiresAt,
				}).Error
			}
		}

		c.JSON(http.StatusOK, map[string]string{"status": "ok"})
	}
}

// appleNotificationPayload 为 Notification V2 的载荷结构
type appleNotificationPayload struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	Data             struct {
		AppAccountToken       string `json:"appAccountToken"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
}

// decodeAppleNotificationPayload 解码 Apple Notification V2 的 signedPayload
func decodeAppleNotificationPayload(signedPayload string) (*appleNotificationPayload, error) {
	parts := strings.Split(signedPayload, ".")
	if len(parts) != 3 {
		return nil, errors.New("signedPayload 不是合法的 JWS 格式")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("解码 signedPayload 失败: %w", err)
	}

	var payload appleNotificationPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, fmt.Errorf("解析 signedPayload JSON 失败: %w", err)
	}
	return &payload, nil
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
