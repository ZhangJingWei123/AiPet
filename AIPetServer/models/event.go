package models

import (
	"time"

	"gorm.io/datatypes"
)

// Event 通用埋点事件表
//
// - user_id: 关联用户（匿名事件可为空）
// - event_name: 事件名称，如 login_success、plus_purchase、llm_reply_completed 等
// - properties: 事件属性，采用 JSONB 以便灵活扩展
// - platform: 事件来源平台，例如 ios、server、admin
// - created_at: 事件产生时间
type Event struct {
	ID         uint           `gorm:"primaryKey" json:"id"`
	UserID     *uint          `gorm:"index" json:"user_id,omitempty"`
	EventName  string         `gorm:"size:128;index" json:"event_name"`
	Properties datatypes.JSON `gorm:"type:jsonb" json:"properties"`
	Platform   string         `gorm:"size:32;index" json:"platform"`
	CreatedAt  time.Time      `json:"created_at"`
}

