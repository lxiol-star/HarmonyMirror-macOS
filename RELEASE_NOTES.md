# 发布说明

## 仓库关系

### 私有仓库 (HarmonyMirror)
- **地址**: https://github.com/lxiol-star/HarmonyMirror (私有)
- **用途**: 完整开发历史，包含所有实验性代码和真实测试环境信息
- **分支**:
  - `DevEcoCastMac_codex2kimi2codex`: 主开发分支
  - `release/v1.0-public-ready`: 公开发布准备分支

### 公开仓库 (HarmonyMirror-macOS)
- **地址**: https://github.com/lxiol-star/HarmonyMirror-macOS (公开)
- **用途**: 清理后的公开版本，已脱敏所有敏感信息
- **分支**:
  - `main`: 完整版本（包含 HarmonyAgent）
  - `no-agent`: 简化版本（纯 hdc 方案）

## 版本信息

### v1.0 (2026-04-27)

**测试环境**:
- macOS 26.4.1
- HarmonyOS 4.0+ (HUAWEI Mate 70 Pro+, MatePad Pro)

**核心功能**:
- ✅ USB/Wi-Fi 自动发现和连接
- ✅ 60fps H.264 硬件解码投屏
- ✅ HarmonyAgent 低延迟输入 (<2ms)
- ✅ 触摸/滑动/长按控制
- ✅ 横竖屏自动切换
- ✅ macOS 触控板手势支持

**已知限制**:
- 锁屏/密码界面因系统安全限制无法远程操作
- 边缘手势不完整（已改用 uitest，桌面可用）
- 首帧延迟约 2 秒（关键帧间隔）

## 发布流程

### 从私有仓库发布到公开仓库

1. **准备发布分支**
   ```bash
   git checkout DevEcoCastMac_codex2kimi2codex
   git checkout -b release/v1.0-public-ready
   ```

2. **脱敏处理**
   - 替换所有真实 IP 地址为示例地址
   - 移除设备特定信息
   - 添加 backups/ 到 .gitignore

3. **创建干净历史**
   ```bash
   git checkout --orphan clean-main
   git add [核心文件]
   git commit -m "feat: HarmonyMirror v1.0"
   ```

4. **推送到公开仓库**
   ```bash
   git remote add public git@github.com:lxiol-star/HarmonyMirror-macOS.git
   git push public clean-main:main --force
   ```

5. **创建简化版分支**
   ```bash
   git checkout -b clean-no-agent
   git rm -r agent/
   git commit -m "feat: 简化版本"
   git push public clean-no-agent:no-agent --force
   ```

## 维护说明

### 私有仓库
- 保留完整开发历史
- 可包含真实测试环境信息
- 用于日常开发和实验

### 公开仓库
- 定期从私有仓库同步功能更新
- 每次同步前必须脱敏处理
- 使用干净的 Git 历史（无敏感信息）

## 更新日志

### 2026-04-27
- 初始公开发布 v1.0
- 创建 main 和 no-agent 两个分支
- 完成敏感信息脱敏处理
- 清理 Git 历史记录
