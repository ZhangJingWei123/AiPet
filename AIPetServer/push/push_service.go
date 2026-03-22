package push

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
	"gorm.io/gorm"

	"AIPetServer/models"
)

// Config 是从 main.AppConfig 抽象出来的最小 APNs 配置
type Config struct {
	AuthKeyPath string
	AuthKey     string
	KeyID       string
	TeamID      string
	BundleID    string
	Environment string // sandbox / production
}

// PushService 定义推送接口
type PushService interface {
	// SendCareNotification 向指定用户发送“思念”通知
	SendCareNotification(userID uint, message string) error
}

// apnsPushService 使用 APNs Token 方式推送
type apnsPushService struct {
	db     *gorm.DB
	conf   Config
	client *apns2.Client
}

// noopPushService 在未配置 APNs 时的空实现，避免影响主流程
type noopPushService struct{}

func (n *noopPushService) SendCareNotification(userID uint, message string) error {
	log.Printf("[push][noop] skip care notification, userID=%d, message=%s", userID, message)
	return nil
}

// NewPushService 根据配置构建实际的推送服务；
// 当配置不完整时，返回 noop 实现，仅打日志。
type appConfigView interface {
	GetAPNsAuthKeyPath() string
	GetAPNsAuthKey() string
	GetAPNsKeyID() string
	GetAPNsTeamID() string
	GetAPNsBundleID() string
	GetAPNsEnvironment() string
}

func NewPushService(db *gorm.DB, appCfg appConfigView) PushService {
	conf := Config{
		AuthKeyPath: appCfg.GetAPNsAuthKeyPath(),
		AuthKey:     appCfg.GetAPNsAuthKey(),
		KeyID:       appCfg.GetAPNsKeyID(),
		TeamID:      appCfg.GetAPNsTeamID(),
		BundleID:    appCfg.GetAPNsBundleID(),
		Environment: strings.ToLower(appCfg.GetAPNsEnvironment()),
	}

	if conf.Environment == "" {
		conf.Environment = "sandbox"
	}

	// 配置项不完整时，直接返回 noop
	if conf.KeyID == "" || conf.TeamID == "" || conf.BundleID == "" || (conf.AuthKeyPath == "" && conf.AuthKey == "") {
		log.Printf("[push] APNs 配置不完整，使用 noop 推送实现")
		return &noopPushService{}
	}

	authKey, err := loadAuthKey(conf)
	if err != nil {
		log.Printf("[push] 加载 APNs AuthKey 失败，降级为 noop: %v", err)
		return &noopPushService{}
	}

	tkn := &token.Token{
		AuthKey: authKey,
		KeyID:   conf.KeyID,
		TeamID:  conf.TeamID,
	}
	client := apns2.NewTokenClient(tkn)
	if conf.Environment == "production" {
		client = client.Production()
	} else {
		client = client.Development()
	}

	log.Printf("[push] APNs 推送服务已初始化，环境=%s", conf.Environment)
	return &apnsPushService{
		db:     db,
		conf:   conf,
		client: client,
	}
}

func loadAuthKey(conf Config) (*ecdsa.PrivateKey, error) {
	if conf.AuthKeyPath != "" {
		return token.AuthKeyFromFile(conf.AuthKeyPath)
	}
	if conf.AuthKey == "" {
		return nil, errors.New("empty auth key")
	}
	// 将纯文本内容写入临时文件再加载，避免修改第三方库
	f, err := os.CreateTemp("", "apns_auth_*.p8")
	if err != nil {
		return nil, err
	}
	defer func(name string) {
		_ = os.Remove(name)
	}(f.Name())
	if _, err := f.Write([]byte(conf.AuthKey)); err != nil {
		_ = f.Close()
		return nil, err
	}
	_ = f.Close()
	return token.AuthKeyFromFile(f.Name())
}

// SendCareNotification 实现 PushService 接口
func (s *apnsPushService) SendCareNotification(userID uint, message string) error {
	var user models.User
	if err := s.db.First(&user, userID).Error; err != nil {
		return fmt.Errorf("query user failed: %w", err)
	}
	if user.APNSToken == "" {
		return fmt.Errorf("user %d has empty APNS token", userID)
	}

	n := &apns2.Notification{
		DeviceToken: user.APNSToken,
		Topic:       s.conf.BundleID,
	}

	// 简单 payload：仅包含提示文案
	payload := fmt.Sprintf(`{"aps":{"alert":{"title":"%s","body":"%s"},"sound":"default"}}`,
		escapeJSONString("你的 AIPet 在想你"), escapeJSONString(message))
	n.Payload = []byte(payload)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res, err := s.client.PushWithContext(ctx, n)
	if err != nil {
		return fmt.Errorf("apns push error: %w", err)
	}
	if res.Sent() {
		log.Printf("[push] care notification sent, userID=%d, apnsID=%s", userID, res.ApnsID)
		return nil
	}
	return fmt.Errorf("apns push failed: status=%d, reason=%s", res.StatusCode, res.Reason)
}

// escapeJSONString 处理简单的 JSON 转义
func escapeJSONString(s string) string {
	replacer := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "\r", "\\r", "\t", "\\t")
	return replacer.Replace(s)
}
