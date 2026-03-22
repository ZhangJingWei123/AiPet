package main

import (
	"context"
	"log"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/utils"

	"github.com/redis/go-redis/v9"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"AIPetServer/auth"
	"AIPetServer/cache"
	"AIPetServer/handlers"
	"AIPetServer/models"
	"AIPetServer/push"
)

// AppConfig 保存运行时配置
type AppConfig struct {
	DatabaseURL string
	JWTSecret   string

	RedisAddr     string
	RedisPassword string
	RedisDB       int

	TencentSecretID   string
	TencentSecretKey  string
	TencentAppID      string
	TencentSignName   string
	TencentTemplateID string
	TencentRegion     string

	// APNs 推送相关配置（基于 Token 验证）
	APNsAuthKeyPath string // p8 私钥文件路径，可选
	APNsAuthKey     string // 若不使用文件，可通过环境变量直接注入私钥内容
	APNsKeyID       string // Key ID
	APNsTeamID      string // Apple Developer Team ID
	APNsBundleID    string // 应用 Bundle ID，用作 Topic
	APNsEnvironment string // sandbox / production
}

// 以下 getter 用于 push 模块通过接口访问 APNs 配置，降低耦合
func (c AppConfig) GetAPNsAuthKeyPath() string  { return c.APNsAuthKeyPath }
func (c AppConfig) GetAPNsAuthKey() string      { return c.APNsAuthKey }
func (c AppConfig) GetAPNsKeyID() string        { return c.APNsKeyID }
func (c AppConfig) GetAPNsTeamID() string       { return c.APNsTeamID }
func (c AppConfig) GetAPNsBundleID() string     { return c.APNsBundleID }
func (c AppConfig) GetAPNsEnvironment() string  { return c.APNsEnvironment }

func loadConfig() AppConfig {
    redisDB := 0
    if v := os.Getenv("REDIS_DB"); v != "" {
        if n, err := strconv.Atoi(v); err == nil {
            redisDB = n
        }
    }

	cfg := AppConfig{
		DatabaseURL: os.Getenv("DATABASE_URL"),
		JWTSecret:   os.Getenv("JWT_SECRET"),

		RedisAddr:     os.Getenv("REDIS_ADDR"),
		RedisPassword: os.Getenv("REDIS_PASSWORD"),
		RedisDB:       redisDB,

		TencentSecretID:  os.Getenv("TENCENT_SMS_SECRET_ID"),
        TencentSecretKey: os.Getenv("TENCENT_SMS_SECRET_KEY"),
		TencentAppID:     os.Getenv("TENCENT_SMS_APP_ID"),
		TencentSignName:  os.Getenv("TENCENT_SMS_SIGN_NAME"),
		TencentTemplateID: os.Getenv("TENCENT_SMS_TEMPLATE_ID"),
		TencentRegion:    os.Getenv("TENCENT_SMS_REGION"),

		APNsAuthKeyPath: os.Getenv("APNS_AUTH_KEY_PATH"),
		APNsAuthKey:     os.Getenv("APNS_AUTH_KEY"),
		APNsKeyID:       os.Getenv("APNS_KEY_ID"),
		APNsTeamID:      os.Getenv("APNS_TEAM_ID"),
		APNsBundleID:    os.Getenv("APNS_BUNDLE_ID"),
		APNsEnvironment: os.Getenv("APNS_ENV"),
	}

	if cfg.TencentRegion == "" {
		cfg.TencentRegion = "ap-guangzhou"
	}
	if cfg.APNsEnvironment == "" {
		cfg.APNsEnvironment = "sandbox"
	}

    return cfg
}

func mustInitDB(cfg AppConfig) *gorm.DB {
    if cfg.DatabaseURL == "" {
        log.Fatal("DATABASE_URL 未配置")
    }

    db, err := gorm.Open(postgres.Open(cfg.DatabaseURL), &gorm.Config{})
    if err != nil {
        log.Fatalf("连接数据库失败: %v", err)
    }

	if err := db.AutoMigrate(&models.User{}, &models.DailyUsage{}, &models.Event{}, &models.Order{}, &models.ChatMessage{}, &models.MemoryEmbedding{}); err != nil {
		log.Fatalf("数据库自动迁移失败: %v", err)
	}

    return db
}

func initSMSStore(cfg AppConfig) auth.CodeStore {
    // 优先使用 Redis, 失败则回退到内存 Map
    if cfg.RedisAddr != "" {
        rdb := redis.NewClient(&redis.Options{
            Addr:     cfg.RedisAddr,
            Password: cfg.RedisPassword,
            DB:       cfg.RedisDB,
        })

        ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
        defer cancel()
        if err := rdb.Ping(ctx).Err(); err != nil {
            log.Printf("Redis 不可用，使用内存验证码存储: %v", err)
        } else {
            log.Printf("使用 Redis 存储短信验证码: %s", cfg.RedisAddr)
            return auth.NewRedisCodeStore(rdb)
        }
    }

    log.Printf("未配置 Redis，使用内存验证码存储")
    return auth.NewMemoryCodeStore()
}

func initSMSSender(cfg AppConfig) auth.SMSSender {
    // 如果未配置 SecretId/Key 或 AppID，则默认使用空实现，仅在日志中提示
    if cfg.TencentSecretID == "" || cfg.TencentSecretKey == "" || cfg.TencentAppID == "" || cfg.TencentTemplateID == "" || cfg.TencentSignName == "" {
        log.Printf("腾讯云短信未完全配置，将跳过真实短信发送，仅记录日志")
        return auth.NewNoopSMSSender()
    }
    sender, err := auth.NewTencentSMSSender(
        cfg.TencentSecretID,
        cfg.TencentSecretKey,
        cfg.TencentRegion,
        cfg.TencentAppID,
        cfg.TencentSignName,
        cfg.TencentTemplateID,
    )
    if err != nil {
        log.Printf("初始化腾讯云短信失败，回退到空实现: %v", err)
        return auth.NewNoopSMSSender()
    }
    return sender
}

func main() {
	cfg := loadConfig()

	db := mustInitDB(cfg)
	smsStore := initSMSStore(cfg)
	smsSender := initSMSSender(cfg)
	semanticCache := cache.NewSemanticCache()
	pushService := push.NewPushService(db, cfg)

    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    addr := net.JoinHostPort("0.0.0.0", port)

	h := server.New(server.WithHostPorts(addr))

	// 将核心依赖注入到每个请求上下文
	h.Use(func(ctx context.Context, c *app.RequestContext) {
		c.Set("db", db)
		c.Set("smsStore", smsStore)
		c.Set("smsSender", smsSender)
		c.Set("semanticCache", semanticCache)
		c.Set("pushService", pushService)
		c.Next(ctx)
	})

	// 全局请求埋点
	h.Use(handlers.RequestMetricsMiddleware())

	// 健康检查
	h.GET("/health", func(ctx context.Context, c *app.RequestContext) {
		c.JSON(200, utils.H{"status": "ok"})
	})

	handlers.RegisterAuthRoutes(h, cfg.JWTSecret)
	handlers.RegisterMembershipRoutes(h, cfg.JWTSecret)
	handlers.RegisterChatRoutes(h, cfg.JWTSecret)
	handlers.RegisterAnalyticsRoutes(h, cfg.JWTSecret)
	handlers.RegisterAdminRoutes(h, os.Getenv("ADMIN_TOKEN"))
	handlers.RegisterAppleWebhookRoutes(h)

	// 启动“思念”推送调度器（后台任务，不阻塞主接口）
	if err := push.StartCareScheduler(db, pushService); err != nil {
		log.Printf("启动推送调度器失败: %v", err)
	}

	log.Printf("Hertz 服务启动，监听 %s", addr)
	if err := h.Run(); err != nil {
		log.Fatalf("服务器启动失败: %v", err)
	}
}
