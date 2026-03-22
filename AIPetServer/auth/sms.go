package auth

import (
    "context"
    "crypto/rand"
    "encoding/binary"
    "fmt"
    "log"
    "regexp"
    "sync"
    "time"

    "github.com/redis/go-redis/v9"
    "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common"
    "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/profile"
    smssdk "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/sms/v20210111"
)

// CodeStore 验证码存储接口
type CodeStore interface {
    Set(ctx context.Context, phone, code string, ttl time.Duration) error
    Get(ctx context.Context, phone string) (string, error)
    Delete(ctx context.Context, phone string) error
}

// MemoryCodeStore 内存存储实现
type MemoryCodeStore struct {
    m   map[string]memoryCode
    mu  sync.RWMutex
}

type memoryCode struct {
    Code      string
    ExpiresAt time.Time
}

func NewMemoryCodeStore() *MemoryCodeStore {
    store := &MemoryCodeStore{m: make(map[string]memoryCode)}
    go store.cleanupLoop()
    return store
}

func (s *MemoryCodeStore) Set(ctx context.Context, phone, code string, ttl time.Duration) error {
    s.mu.Lock()
    defer s.mu.Unlock()
    s.m[phone] = memoryCode{Code: code, ExpiresAt: time.Now().Add(ttl)}
    return nil
}

func (s *MemoryCodeStore) Get(ctx context.Context, phone string) (string, error) {
    s.mu.RLock()
    defer s.mu.RUnlock()
    mc, ok := s.m[phone]
    if !ok {
        return "", redis.Nil
    }
    if time.Now().After(mc.ExpiresAt) {
        return "", redis.Nil
    }
    return mc.Code, nil
}

func (s *MemoryCodeStore) Delete(ctx context.Context, phone string) error {
    s.mu.Lock()
    defer s.mu.Unlock()
    delete(s.m, phone)
    return nil
}

func (s *MemoryCodeStore) cleanupLoop() {
    ticker := time.NewTicker(time.Minute)
    defer ticker.Stop()
    for range ticker.C {
        now := time.Now()
        s.mu.Lock()
        for k, v := range s.m {
            if now.After(v.ExpiresAt) {
                delete(s.m, k)
            }
        }
        s.mu.Unlock()
    }
}

// RedisCodeStore 使用 Redis 存储验证码
type RedisCodeStore struct {
    client *redis.Client
}

func NewRedisCodeStore(client *redis.Client) *RedisCodeStore {
    return &RedisCodeStore{client: client}
}

func (s *RedisCodeStore) Set(ctx context.Context, phone, code string, ttl time.Duration) error {
    return s.client.Set(ctx, phone, code, ttl).Err()
}

func (s *RedisCodeStore) Get(ctx context.Context, phone string) (string, error) {
    return s.client.Get(ctx, phone).Result()
}

func (s *RedisCodeStore) Delete(ctx context.Context, phone string) error {
    return s.client.Del(ctx, phone).Err()
}

// 6 位验证码生成
func GenerateVerificationCode() (string, error) {
    var b [8]byte
    if _, err := rand.Read(b[:]); err != nil {
        return "", err
    }
    n := binary.BigEndian.Uint64(b[:]) % 1000000
    return fmt.Sprintf("%06d", n), nil
}

var phoneRegexp = regexp.MustCompile(`^\+?\d{6,20}$`)

// ValidatePhoneNumber 简单手机号格式校验（推荐使用 E.164 格式）
func ValidatePhoneNumber(phone string) bool {
    return phoneRegexp.MatchString(phone)
}

// SMSSender 短信发送接口
type SMSSender interface {
    SendCode(ctx context.Context, phone, code string) error
}

// NoopSMSSender 本地开发用，不真正发短信
type NoopSMSSender struct{}

func NewNoopSMSSender() *NoopSMSSender { return &NoopSMSSender{} }

func (s *NoopSMSSender) SendCode(ctx context.Context, phone, code string) error {
    log.Printf("[NOOP SMS] phone=%s code=%s", phone, code)
    return nil
}

// TencentSMSSender 腾讯云短信实现
type TencentSMSSender struct {
    client   *smssdk.Client
    appID    string
    signName string
    templateID string
}

// NewTencentSMSSender 创建腾讯云 SMS 发送器
func NewTencentSMSSender(secretID, secretKey, region, appID, signName, templateID string) (*TencentSMSSender, error) {
    cred := common.NewCredential(secretID, secretKey)
    cpf := profile.NewClientProfile()
    client, err := smssdk.NewClient(cred, region, cpf)
    if err != nil {
        return nil, err
    }
    return &TencentSMSSender{
        client:    client,
        appID:     appID,
        signName:  signName,
        templateID: templateID,
    }, nil
}

func (s *TencentSMSSender) SendCode(ctx context.Context, phone, code string) error {
    req := smssdk.NewSendSmsRequest()
    req.SmsSdkAppId = common.StringPtr(s.appID)
    req.SignName = common.StringPtr(s.signName)
    req.TemplateId = common.StringPtr(s.templateID)
    req.PhoneNumberSet = []*string{common.StringPtr(phone)}
    req.TemplateParamSet = []*string{common.StringPtr(code)}

    _, err := s.client.SendSmsWithContext(ctx, req)
    return err
}

