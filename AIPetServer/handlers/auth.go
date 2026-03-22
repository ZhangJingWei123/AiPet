package handlers

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"

	"AIPetServer/auth"
	"AIPetServer/models"
)

// RegisterAuthRoutes 注册认证相关路由
func RegisterAuthRoutes(h *server.Hertz, jwtSecret string) {
    v1 := h.Group("/v1/auth")

    v1.POST("/apple", AppleLoginHandler(jwtSecret))
    v1.POST("/sms/send", SendSMSCodeHandler())
    v1.POST("/sms/verify", VerifySMSCodeHandler(jwtSecret))
}

// AppleLoginHandler Apple ID 登录
func AppleLoginHandler(jwtSecret string) app.HandlerFunc {
    type request struct {
        IdentityToken string `json:"identityToken" binding:"required"`
    }

    type response struct {
        AccessToken string       `json:"access_token"`
        TokenType   string       `json:"token_type"`
        ExpiresIn   int64        `json:"expires_in"`
        User        *models.User `json:"user"`
    }

	return func(ctx context.Context, c *app.RequestContext) {
        var req request
        if err := c.BindAndValidate(&req); err != nil {
            c.JSON(http.StatusBadRequest, map[string]string{"error": "参数错误"})
            return
        }

		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}

		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库上下文错误"})
			return
		}

        claims, err := auth.VerifyAppleIdentityToken(ctx, req.IdentityToken)
        if err != nil {
            c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
            return
        }

        var user models.User
		if err := db.Where("apple_id = ?", claims.Sub).First(&user).Error; err != nil {
            // 不存在则自动注册
            user = models.User{
                AppleID:  claims.Sub,
                Username: claims.Email,
            }
            if err := db.Create(&user).Error; err != nil {
                c.JSON(http.StatusInternalServerError, map[string]string{"error": "创建用户失败"})
                return
            }
		}

		ttl := 24 * time.Hour
		token, err := auth.GenerateToken(jwtSecret, user.ID, user.AppleID, user.PhoneNumber, ttl)
		if err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "生成 token 失败"})
			return
		}

		// 业务埋点：Apple 登录成功
		if db != nil {
			recordEvent(ctx, db, &user.ID, "login_apple_success", getClientPlatform(c), map[string]interface{}{
				"apple_id":  user.AppleID,
				"user_id":   user.ID,
				"login_type": "apple",
			})
		}

        c.JSON(http.StatusOK, response{
            AccessToken: token,
            TokenType:   "Bearer",
            ExpiresIn:   int64(ttl.Seconds()),
            User:        &user,
        })
    }
}

// SendSMSCodeHandler 发送短信验证码
func SendSMSCodeHandler() app.HandlerFunc {
    type request struct {
        PhoneNumber string `json:"phone_number" binding:"required"`
    }

    type response struct {
        Success bool   `json:"success"`
        Message string `json:"message"`
    }

    return func(ctx context.Context, c *app.RequestContext) {
        var req request
        if err := c.BindAndValidate(&req); err != nil {
            c.JSON(http.StatusBadRequest, map[string]string{"error": "参数错误"})
            return
        }

        if !auth.ValidatePhoneNumber(req.PhoneNumber) {
            c.JSON(http.StatusBadRequest, map[string]string{"error": "手机号格式不合法，建议使用 E.164 格式"})
            return
        }

		smsStoreVal, ok := c.Get("smsStore")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		smsSenderVal, ok := c.Get("smsSender")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}

		smsStore, ok := smsStoreVal.(auth.CodeStore)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "验证码存储配置错误"})
			return
		}
		smsSender, ok := smsSenderVal.(auth.SMSSender)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "短信发送配置错误"})
			return
		}

        code, err := auth.GenerateVerificationCode()
        if err != nil {
            c.JSON(http.StatusInternalServerError, map[string]string{"error": "生成验证码失败"})
            return
        }

		if err := smsStore.Set(ctx, req.PhoneNumber, code, 5*time.Minute); err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "存储验证码失败"})
			return
		}

		if err := smsSender.SendCode(ctx, req.PhoneNumber, code); err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "发送短信失败"})
			return
		}

        c.JSON(http.StatusOK, response{Success: true, Message: "验证码已发送"})
    }
}

// VerifySMSCodeHandler 验证短信验证码并登录
func VerifySMSCodeHandler(jwtSecret string) app.HandlerFunc {
    type request struct {
        PhoneNumber string `json:"phone_number" binding:"required"`
        Code        string `json:"code" binding:"required"`
    }

    type response struct {
        AccessToken string       `json:"access_token"`
        TokenType   string       `json:"token_type"`
        ExpiresIn   int64        `json:"expires_in"`
        User        *models.User `json:"user"`
    }

    return func(ctx context.Context, c *app.RequestContext) {
        var req request
        if err := c.BindAndValidate(&req); err != nil {
            c.JSON(http.StatusBadRequest, map[string]string{"error": "参数错误"})
            return
        }

        if !auth.ValidatePhoneNumber(req.PhoneNumber) {
            c.JSON(http.StatusBadRequest, map[string]string{"error": "手机号格式不合法"})
            return
        }

		smsStoreVal, ok := c.Get("smsStore")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}

		smsStore, ok := smsStoreVal.(auth.CodeStore)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "验证码存储配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		stored, err := smsStore.Get(ctx, req.PhoneNumber)
		if err != nil {
			if errors.Is(err, redis.Nil) {
				c.JSON(http.StatusBadRequest, map[string]string{"error": "验证码不存在或已过期"})
                return
            }
            c.JSON(http.StatusInternalServerError, map[string]string{"error": "获取验证码失败"})
            return
        }

		if stored != req.Code {
			c.JSON(http.StatusBadRequest, map[string]string{"error": "验证码错误"})
			return
		}

        // 验证成功后删除验证码
		_ = smsStore.Delete(ctx, req.PhoneNumber)

		var user models.User
		if err := db.Where("phone_number = ?", req.PhoneNumber).First(&user).Error; err != nil {
            // 若用户不存在则自动注册
            user = models.User{
                PhoneNumber: req.PhoneNumber,
                Username:    req.PhoneNumber,
            }
			if err := db.Create(&user).Error; err != nil {
                c.JSON(http.StatusInternalServerError, map[string]string{"error": "创建用户失败"})
                return
            }
		}

		ttl := 24 * time.Hour
		token, err := auth.GenerateToken(jwtSecret, user.ID, user.AppleID, user.PhoneNumber, ttl)
		if err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "生成 token 失败"})
			return
		}

		c.JSON(http.StatusOK, response{
			AccessToken: token,
			TokenType:   "Bearer",
			ExpiresIn:   int64(ttl.Seconds()),
			User:        &user,
		})

		// 业务埋点：短信登录成功
		if db != nil {
			recordEvent(ctx, db, &user.ID, "login_sms_success", getClientPlatform(c), map[string]interface{}{
				"phone_number": user.PhoneNumber,
				"login_type":  "sms",
			})
		}
	}
}
