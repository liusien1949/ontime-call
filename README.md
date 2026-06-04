# 🍚 ontime-call（饭点提醒）

一个基于 PowerShell + Windows Forms 的桌面定时提醒工具，用于在午饭、晚饭和加班结束时弹出提醒窗口。支持多主题皮肤、单次提醒、贪睡、出差模式等功能，常驻系统托盘，安静运行。

## ✨ 功能特性

- **每日定时提醒** — 午饭（11:27）、晚饭（17:37）、加班结束（20:57），可自定义时间
- **单次提醒** — 支持"按当前时间顺延"和"固定时刻"两种模式，灵活设置一次性提醒
- **贪睡功能** — 提醒弹出后可贪睡延迟再提醒
- **出差模式** — 一键切换，暂时屏蔽所有提醒
- **单独屏蔽** — 可独立开关某一条每日提醒
- **多主题皮肤** — 内置 5 种界面风格：
  - ☀️ 浅色模式 | 🌙 深色模式 | 🎀 库洛米主题 | ⚡ 皮卡丘主题 | 🐷 猪猪侠主题
- **系统托盘驻留** — 最小化到托盘，后台静默运行
- **开机自启** — 可通过设置界面一键开启/关闭，不需要管理员权限
- **单实例运行** — 防止重复启动

## 📸 界面预览

主界面包含实时时钟、提醒状态面板、每日提醒列表和快捷操作按钮。

## 🚀 快速开始

### 环境要求

- Windows 10 / Windows 11
- PowerShell 5.1 或更高版本（系统自带）
- 无需管理员权限

### 启动方式

**方式一：直接运行 VBS 脚本（推荐）**

双击 `meal-reminder.vbs`，程序将以隐藏窗口启动并驻留系统托盘。

**方式二：通过 PowerShell 运行**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File ".\meal-reminder.ps1"
```

**方式三：设为开机自启**

打开程序主界面 → 点击"设置" → 勾选"开机自动启动"。程序会自动在启动文件夹创建快捷方式。

## 📁 项目结构

```
ontime-call/
├── meal-reminder.vbs          # 入口脚本，静默启动 PowerShell 主程序
├── meal-reminder.ps1           # 主程序，Windows Forms GUI 应用 (~3170 行)
├── meal-reminder.config.json   # 配置文件（运行时自动生成）
├── assets/
│   └── themes/
│       ├── kuromi-badge.png    # 库洛米主题图标
│       ├── kuromi-banner.png   # 库洛米主题横幅
│       ├── kuromi-popup.png    # 库洛米主题弹窗图
│       ├── pikachu-badge.png   # 皮卡丘主题图标
│       ├── pikachu-banner.png  # 皮卡丘主题横幅
│       ├── pikachu-popup.png   # 皮卡丘主题弹窗图
│       └── cache/              # 主题图片缓存（运行时自动生成，已 gitignore）
├── .gitignore
└── README.md
```

## ⚙️ 配置说明

配置文件 `meal-reminder.config.json` 结构：

```json
{
    "Version": 4,
    "Mode": "Company",
    "Preferences": {
        "Theme": "Pikachu"
    },
    "SingleReminder": {
        "Enabled": false,
        "At": null,
        "Triggered": false,
        "ScheduleMode": "Relative",
        "Label": "单次提醒",
        "Message": "你设置的单次提醒时间到了。"
    },
    "SnoozeReminder": {
        "Enabled": false,
        "Until": null,
        "Title": "",
        "Message": "",
        "KeyName": ""
    },
    "DailyReminders": {
        "Lunch": {
            "Enabled": true,
            "Time": "11:27",
            "Title": "午饭时间到",
            "Message": "中午 11:27 到啦，先去吃饭。"
        },
        "Dinner": {
            "Enabled": true,
            "Time": "17:37",
            "Title": "晚饭时间到",
            "Message": "下午 17:37 到啦，去吃晚饭。"
        },
        "Overtime": {
            "Enabled": true,
            "Time": "20:57",
            "Title": "加班结束",
            "Message": "晚上 20:57 到啦，今天可以收工了。"
        }
    }
}
```

| 字段 | 说明 |
|------|------|
| `Mode` | 运行模式：`Company`（公司上班）/ `Trip`（出差中，屏蔽提醒） |
| `Preferences.Theme` | 界面主题：`Light` / `Dark` / `Kuromi` / `Pikachu` / `PigHero` |
| `SingleReminder.ScheduleMode` | 单次提醒模式：`Relative`（按当前时间顺延）/ `ClockTime`（固定时刻） |
| `DailyReminders.*.Time` | 每日提醒时间，格式 `HH:mm` |
| `DailyReminders.*.Enabled` | 是否启用该条提醒 |

## 🛠️ 技术实现

- **GUI 框架**：Windows Forms（通过 PowerShell 直接调用 .NET）
- **主题系统**：纯 GDI+ 绘制，渐变面板 + 圆角玻璃效果 + 颜色动画过渡
- **主题图片处理**：Flood-fill 边缘透明化 + 缩放 + 缓存机制
- **单实例互斥**：基于 `System.Threading.Mutex`（命名互斥体 `Local\meal-reminder-single-instance`）
- **IPC 唤醒**：通过 `meal-reminder.show` 文件时间戳实现重复启动时唤醒已有窗口
- **开机自启**：在用户启动文件夹创建 `.lnk` 快捷方式，无需注册表或计划任务

## 📝 许可证

MIT License

---

🍚 记得按时吃饭！
