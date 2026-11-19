<img src="./icon.png" width="96" height="96" alt="NoyAcg" />

# NoyACG OHOS

一个用 ArkTS 和 ArkUI 写的 NoyACG 第三方 HarmonyOS 原生客户端（Stage 模型，API 26）。纯粹出于个人学习与日常阅读习惯而做，没有套壳 WebView，界面和交互尽量贴近鸿蒙系统原本的质感。

## 主要功能

- 首页推荐、分类浏览、排行榜、搜索与标签筛选
- 漫画详情、目录/章节切换、多种翻页与条漫阅读模式
- 收藏夹管理、阅读历史记录、离线缓存与下载管理
- 社区帖子浏览、评论互动与每日签到
- 账号会话管理、主题色与深浅色模式
- 支持简体中文、繁體中文、English 三套本地化文案切换

## 构建与测试

环境要求：DevEco Studio（HarmonyOS SDK API 26）、`ohpm`、`hvigorw`。

```powershell
ohpm install --all
hvigorw.bat test --no-daemon
hvigorw.bat clean assembleHap --no-daemon
```

构建完成后，未签名安装包输出至：

`entry/build/default/outputs/default/NoyACG-OHOS-unsigned.hap`

如需在真机上安装调试，请在 DevEco Studio 中配置个人调试签名后运行。

## 免责声明

1. 本项目仅作为个人技术学习与第三方开源客户端实现，**不存储、不生产、不分发、亦不托管任何漫画、图片或社区内容**。所有在线数据均由用户客户端直接向对应第三方站点请求获取。
2. 请严格遵守所在国家与地区的法律法规，切勿将本软件用于任何违反当地法律或站点服务条款的用途。
3. 使用本软件所产生的一切行为及后果均由使用者本人自行承担，项目作者不对此承担任何连带责任。
4. 如涉及任何版权或内容争议，请联系对应内容源站点处理。
