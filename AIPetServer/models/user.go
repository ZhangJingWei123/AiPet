package models

import "time"

// User 用户模型
// 使用 GORM 映射到 PostgreSQL
type User struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	AppleID     string    `gorm:"uniqueIndex;size:128" json:"apple_id"`
	PhoneNumber string    `gorm:"uniqueIndex;size:32" json:"phone_number"`
	Username    string    `gorm:"size:64" json:"username"`
	AvatarURL   string    `gorm:"size:256" json:"avatar_url"`
	CreatedAt   time.Time `json:"created_at"`

	// APNs 相关信息
	APNSToken        string     `gorm:"size:256" json:"apns_token"`          // 设备 Token
	LastInteractionAt *time.Time `json:"last_interaction_at,omitempty"` // 最近一次与宠物交互时间

	// 会员相关字段
	IsPlusMember  bool       `gorm:"not null;default:false" json:"is_plus_member"`
	PlusExpiresAt *time.Time `json:"plus_expires_at"`
}

// IsPlusActive 当前时间下该用户是否处于有效的 Plus 会员状态
func (u *User) IsPlusActive(now time.Time) bool {
	if u == nil {
		return false
	}
	if !u.IsPlusMember || u.PlusExpiresAt == nil {
		return false
	}
	return u.PlusExpiresAt.After(now)
}

// DailyUsage 记录用户每日对话次数，用于限流
type DailyUsage struct {
	ID               uint      `gorm:"primaryKey" json:"id"`
	UserID           uint      `gorm:"index:idx_user_date,unique" json:"user_id"`
	Date             time.Time `gorm:"type:date;index:idx_user_date,unique" json:"date"`
	InteractionCount int       `gorm:"not null;default:0" json:"interaction_count"`
	CreatedAt        time.Time `json:"created_at"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// OrderStatus 订单状态
type OrderStatus string

const (
	OrderStatusPending   OrderStatus = "PENDING"
	OrderStatusCompleted OrderStatus = "COMPLETED"
	OrderStatusFailed    OrderStatus = "FAILED"
)

// Order 订阅订单表，对应 StoreKit 2 交易记录
//
// 通过 app_account_token 与 original_transaction_id 关联用户与长期订阅关系。
type Order struct {
	ID uint `gorm:"primaryKey" json:"id"`

	// 业务侧用户 ID，可选但推荐填写，方便直接关联用户
	UserID uint `gorm:"index" json:"user_id"`

	AppAccountToken       string      `gorm:"size:128;index" json:"app_account_token"`
	TransactionID         string      `gorm:"size:128;uniqueIndex" json:"transaction_id"`
	OriginalTransactionID string      `gorm:"size:128;index" json:"original_transaction_id"`
	Status                OrderStatus `gorm:"size:16;index" json:"status"`
	ExpiresDate           *time.Time  `json:"expires_date"`
	Environment           string      `gorm:"size:16" json:"environment"` // production / sandbox

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ChatMessage 对话消息持久化
//
// 为了尽量与前端保持解耦，pet_id 使用字符串存储（通常是 UUID）。
type ChatMessage struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID uint   `gorm:"index" json:"user_id"`
	PetID  string `gorm:"size:64;index" json:"pet_id"`
	Role   string `gorm:"size:16;index" json:"role"` // user / assistant / system 等

	Content    string    `gorm:"type:text" json:"content"`
	TokensUsed int       `gorm:"notnull;default:0" json:"tokens_used"`
	CreatedAt  time.Time `json:"created_at"`
}

// MemoryEmbedding 长期记忆向量存储表
//
// 通过简单的向量/二进制 blob 方式模拟向量数据库，后续可无感迁移到
// 专门的向量检索引擎（如 pgvector / Milvus 等）。
type MemoryEmbedding struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID uint   `gorm:"index" json:"user_id"`
	Content string `gorm:"type:text" json:"content"`

	// Embedding 使用 bytea 模拟向量存储，内部可以存放二进制向量或
	// 编码后的 JSON/其他格式，当前实现中使用 sha256 hash 作为 mock 向量。
	Embedding []byte `gorm:"type:bytea" json:"-"`

	CreatedAt time.Time `json:"created_at"`
}
