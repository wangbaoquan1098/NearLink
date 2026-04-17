# NearLink 变更记录

## 2026-04-17

### 稳定性修复

- 修复 `iOS` 取消接收后立刻反向发送给 `Android` 时，偶发因 `fileInfoAck` 未确认而断开的情况。
- 在取消传输后增加短冷却窗口，降低旧轮次残留控制包影响下一轮握手的概率。
- 为接收端 `fileInfoAck` 增加一次短延迟补发，提升首轮握手稳定性。
- 优化取消后的缓冲区清理时机，减少角色快速切换时的残包干扰。

### 发送流程修复

- 修复 `Android` 端进入文件选择器后未选中文件、直接返回时，误发送上一次已选文件的问题。
- 发送入口现在会在每次选择前清空旧文件状态，避免复用陈旧选择结果。
- 文件真正开始发送后会立即清理已消费的选择状态，避免后续误触发。

### iOS 选择器兼容性

- 优化 `iOS` 上 `image_picker -> file_picker` 的切换时序。
- 处理 `PlatformException(multiple_request, Cancelled by a second request, null, null)`，避免在用户正常取消选择时产生误导性异常日志。

### 回归重点

- `Android -> iOS` 发送中，`iOS` 取消后立即 `iOS -> Android` 重发。
- 连续多轮“发送 -> 取消 -> 立刻重发”。
- `Android` 文件选择器中直接返回，不应自动发送旧文件。
- `iOS` 相册取消后再次选文件，不应出现 `multiple_request` 异常。
