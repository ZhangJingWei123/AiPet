package auth

import (
    "context"
    "fmt"
    "sync"
    "time"

    "github.com/redis/go-redis/v9"
)

type SMSGuard interface {
    AllowSend(ctx context.Context, phone string) (bool, string, error)
    RecordSend(ctx context.Context, phone string) error
    AllowVerify(ctx context.Context, phone string) (bool, string, error)
    RecordVerifyFailure(ctx context.Context, phone string) (int64, error)
    ResetVerifyFailures(ctx context.Context, phone string) error
}

type RedisSMSGuard struct {
    rdb *redis.Client
    minSendInterval time.Duration
    maxSendsPerDay int64
    maxVerifyFailures int64
    verifyFailureWindow time.Duration
}

func NewRedisSMSGuard(rdb *redis.Client) *RedisSMSGuard {
    return &RedisSMSGuard{
        rdb: rdb,
        minSendInterval: 60 * time.Second,
        maxSendsPerDay: 10,
        maxVerifyFailures: 5,
        verifyFailureWindow: 10 * time.Minute,
    }
}

func (g *RedisSMSGuard) sendLockKey(phone string) string { return fmt.Sprintf("sms:send:lock:%s", phone) }
func (g *RedisSMSGuard) sendCountKey(phone string) string { return fmt.Sprintf("sms:send:count:%s:%s", time.Now().UTC().Format("20060102"), phone) }
func (g *RedisSMSGuard) verifyFailKey(phone string) string { return fmt.Sprintf("sms:verify:fail:%s", phone) }

func (g *RedisSMSGuard) AllowSend(ctx context.Context, phone string) (bool, string, error) {
    ok, err := g.rdb.SetNX(ctx, g.sendLockKey(phone), "1", g.minSendInterval).Result()
    if err != nil {
        return false, "", err
    }
    if !ok {
        ttl, _ := g.rdb.TTL(ctx, g.sendLockKey(phone)).Result()
        if ttl > 0 {
            return false, fmt.Sprintf("发送过于频繁，请 %d 秒后重试", int64(ttl.Seconds())+1), nil
        }
        return false, "发送过于频繁，请稍后重试", nil
    }

    n, err := g.rdb.Incr(ctx, g.sendCountKey(phone)).Result()
    if err != nil {
        return false, "", err
    }
    if n == 1 {
        _ = g.rdb.Expire(ctx, g.sendCountKey(phone), 24*time.Hour).Err()
    }
    if n > g.maxSendsPerDay {
        return false, "今日验证码发送次数已达上限，请明天再试", nil
    }
    return true, "", nil
}

func (g *RedisSMSGuard) RecordSend(ctx context.Context, phone string) error {
    return nil
}

func (g *RedisSMSGuard) AllowVerify(ctx context.Context, phone string) (bool, string, error) {
    n, err := g.rdb.Get(ctx, g.verifyFailKey(phone)).Int64()
    if err != nil && err != redis.Nil {
        return false, "", err
    }
    if n >= g.maxVerifyFailures {
        ttl, _ := g.rdb.TTL(ctx, g.verifyFailKey(phone)).Result()
        if ttl > 0 {
            return false, fmt.Sprintf("尝试次数过多，请 %d 秒后重试", int64(ttl.Seconds())+1), nil
        }
        return false, "尝试次数过多，请稍后重试", nil
    }
    return true, "", nil
}

func (g *RedisSMSGuard) RecordVerifyFailure(ctx context.Context, phone string) (int64, error) {
    n, err := g.rdb.Incr(ctx, g.verifyFailKey(phone)).Result()
    if err != nil {
        return 0, err
    }
    if n == 1 {
        _ = g.rdb.Expire(ctx, g.verifyFailKey(phone), g.verifyFailureWindow).Err()
    }
    return n, nil
}

func (g *RedisSMSGuard) ResetVerifyFailures(ctx context.Context, phone string) error {
    return g.rdb.Del(ctx, g.verifyFailKey(phone)).Err()
}

type MemorySMSGuard struct {
    mu sync.Mutex
    lastSend map[string]time.Time
    sendCount map[string]int64
    verifyFail map[string]memoryVerifyFail
    minSendInterval time.Duration
    maxSendsPerDay int64
    maxVerifyFailures int64
    verifyFailureWindow time.Duration
}

type memoryVerifyFail struct {
    Count int64
    ExpiresAt time.Time
}

func NewMemorySMSGuard() *MemorySMSGuard {
    return &MemorySMSGuard{
        lastSend: make(map[string]time.Time),
        sendCount: make(map[string]int64),
        verifyFail: make(map[string]memoryVerifyFail),
        minSendInterval: 60 * time.Second,
        maxSendsPerDay: 10,
        maxVerifyFailures: 5,
        verifyFailureWindow: 10 * time.Minute,
    }
}

func (g *MemorySMSGuard) AllowSend(ctx context.Context, phone string) (bool, string, error) {
    g.mu.Lock()
    defer g.mu.Unlock()

    if t, ok := g.lastSend[phone]; ok {
        if left := g.minSendInterval - time.Since(t); left > 0 {
            return false, fmt.Sprintf("发送过于频繁，请 %d 秒后重试", int64(left.Seconds())+1), nil
        }
    }
    key := time.Now().UTC().Format("20060102") + ":" + phone
    g.sendCount[key]++
    if g.sendCount[key] > g.maxSendsPerDay {
        return false, "今日验证码发送次数已达上限，请明天再试", nil
    }
    return true, "", nil
}

func (g *MemorySMSGuard) RecordSend(ctx context.Context, phone string) error {
    g.mu.Lock()
    defer g.mu.Unlock()
    g.lastSend[phone] = time.Now()
    return nil
}

func (g *MemorySMSGuard) AllowVerify(ctx context.Context, phone string) (bool, string, error) {
    g.mu.Lock()
    defer g.mu.Unlock()

    if v, ok := g.verifyFail[phone]; ok {
        if time.Now().After(v.ExpiresAt) {
            delete(g.verifyFail, phone)
            return true, "", nil
        }
        if v.Count >= g.maxVerifyFailures {
            left := time.Until(v.ExpiresAt)
            if left > 0 {
                return false, fmt.Sprintf("尝试次数过多，请 %d 秒后重试", int64(left.Seconds())+1), nil
            }
            return false, "尝试次数过多，请稍后重试", nil
        }
    }
    return true, "", nil
}

func (g *MemorySMSGuard) RecordVerifyFailure(ctx context.Context, phone string) (int64, error) {
    g.mu.Lock()
    defer g.mu.Unlock()

    v := g.verifyFail[phone]
    if time.Now().After(v.ExpiresAt) {
        v = memoryVerifyFail{}
    }
    v.Count++
    if v.ExpiresAt.IsZero() {
        v.ExpiresAt = time.Now().Add(g.verifyFailureWindow)
    }
    g.verifyFail[phone] = v
    return v.Count, nil
}

func (g *MemorySMSGuard) ResetVerifyFailures(ctx context.Context, phone string) error {
    g.mu.Lock()
    defer g.mu.Unlock()
    delete(g.verifyFail, phone)
    return nil
}

