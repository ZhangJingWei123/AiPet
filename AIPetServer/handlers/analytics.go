package handlers

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"AIPetServer/auth"
	"AIPetServer/models"
)

// getDBFromContext 从 Hertz 上下文中获取 *gorm.DB
func getDBFromContext(c *app.RequestContext) (*gorm.DB, bool) {
	val, ok := c.Get("db")
	if !ok {
		return nil, false
	}
	db, ok := val.(*gorm.DB)
	return db, ok
}

// getCurrentUserID 从 authClaims 中提取当前用户 ID（若已登录）
func getCurrentUserID(c *app.RequestContext) *uint {
	val, ok := c.Get("authClaims")
	if !ok {
		return nil
	}
	claims, ok := val.(*auth.Claims)
	if !ok {
		return nil
	}
	uid := claims.UserID
	return &uid
}

// getClientPlatform 从请求头中推断平台
//
// 优先读取 X-Client-Platform（例如 ios、web、admin），否则回退到 "server"。
func getClientPlatform(c *app.RequestContext) string {
	if p := string(c.Request.Header.Peek("X-Client-Platform")); p != "" {
		return p
	}
	return "server"
}

// recordEvent 将事件写入 events 表，失败时仅记录日志不打断主流程
func recordEvent(ctx context.Context, db *gorm.DB, userID *uint, eventName, platform string, props map[string]interface{}) {
	if db == nil || eventName == "" {
		return
	}

	var raw datatypes.JSON
	if props != nil {
		b, err := json.Marshal(props)
		if err != nil {
			log.Printf("recordEvent: marshal props failed: %v", err)
		} else {
			raw = datatypes.JSON(b)
		}
	}

	e := &models.Event{
		EventName:  eventName,
		UserID:     userID,
		Platform:   platform,
		Properties: raw,
		CreatedAt:  time.Now(),
	}
	if err := db.WithContext(ctx).Create(e).Error; err != nil {
		log.Printf("recordEvent: create event failed: %v", err)
	}
}

// RequestMetricsMiddleware
//
// 自动记录每个 HTTP 请求的路径、方法、耗时、状态码和关联用户 ID。
// 该中间件依赖上游已注入的 "db"，以及可能存在的 "authClaims"。
func RequestMetricsMiddleware() app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		start := time.Now()
		c.Next(ctx)

		elapsed := time.Since(start)
		db, ok := getDBFromContext(c)
		if !ok {
			return
		}

		path := string(c.Request.Path())
		method := string(c.Request.Method())
		status := c.Response.StatusCode()
		userID := getCurrentUserID(c)
		platform := getClientPlatform(c)

		// 可选：过滤掉健康检查，避免噪音
		if path == "/health" {
			return
		}

		props := map[string]interface{}{
			"path":        path,
			"method":      method,
			"status":      status,
			"duration_ms": elapsed.Milliseconds(),
			"user_agent":  string(c.Request.Header.Peek("User-Agent")),
			"client_ip":   c.ClientIP(),
		}

		recordEvent(ctx, db, userID, "http_request", platform, props)
	}
}

// RegisterAnalyticsRoutes 注册通用埋点上报接口
//
// iOS 客户端通过 /v1/events/track 上报业务事件，后端统一写入 events 表。
func RegisterAnalyticsRoutes(h *server.Hertz, jwtSecret string) {
	g := h.Group("/v1/events")
	g.Use(auth.AuthMiddleware(jwtSecret))

	g.POST("/track", TrackEventHandler())
}

// TrackEventHandler 统一事件上报入口
func TrackEventHandler() app.HandlerFunc {
	type request struct {
		EventName  string                 `json:"event_name" binding:"required"`
		Properties map[string]interface{} `json:"properties"`
		Platform   string                 `json:"platform"`
	}

	type response struct {
		Success bool `json:"success"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		var req request
		if err := c.BindAndValidate(&req); err != nil || req.EventName == "" {
			c.JSON(http.StatusBadRequest, map[string]string{"error": "参数错误"})
			return
		}

		db, ok := getDBFromContext(c)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}

		userID := getCurrentUserID(c)
		platform := req.Platform
		if platform == "" {
			platform = "ios"
		}

		recordEvent(ctx, db, userID, req.EventName, platform, req.Properties)
		c.JSON(http.StatusOK, response{Success: true})
	}
}

