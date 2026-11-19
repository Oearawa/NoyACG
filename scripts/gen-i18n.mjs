/**
 * gen-i18n.mjs —— 生成三套语言资源（Phase 14-L）
 *
 * 为什么用脚本而不是手写三个 JSON：
 * 手写极易出现「key 集合不一致 / 漏翻译 / 重复 key」，而这类错误在编译期不会报，
 * 只会在运行时表现为「显示成另一种语言」或「显示资源 ID」。
 * 本脚本以单一字典为真相源，一次性产出 base / zh_CN / zh_TW，
 * 并由 scripts/check-i18n.mjs 做二次校验（可重复执行）。
 *
 * 用法：node scripts/gen-i18n.mjs
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

/** key: [简体中文, 繁体中文] —— 繁体为真正的繁体用词，非机械字形替换 */
const DICT = {
  // ===== 模块/应用（已有 key，保持兼容） =====
  module_desc: ['NoyAcg 漫画阅读器入口模块', 'NoyAcg 漫畫閱讀器入口模組'],
  EntryAbility_desc: ['NoyAcg 漫画阅读器', 'NoyAcg 漫畫閱讀器'],
  EntryAbility_label: ['NoyAcg', 'NoyAcg'],

  // ===== 一级导航 =====
  tab_home: ['主页', '首頁'],
  tab_latest: ['最新', '最新'],
  tab_shelf: ['收藏', '收藏'],
  tab_user: ['用户', '使用者'],

  // ===== 用户主页 =====
  profile_guest: ['游客', '訪客'],
  profile_login: ['登录', '登入'],
  profile_logout: ['退出登录', '登出'],
  profile_logout_doing: ['退出中...', '登出中...'],
  profile_checking: ['正在校验登录状态...', '正在驗證登入狀態...'],
  profile_check_failed: ['登录状态校验失败', '登入狀態驗證失敗'],
  profile_retry: ['重试', '重試'],
  profile_session_ok: ['会话已通过服务端校验', '工作階段已通過伺服器驗證'],
  profile_login_hint: ['登录后可同步收藏、消息与阅读进度', '登入後可同步收藏、訊息與閱讀進度'],
  profile_about: ['关于', '關於'],
  profile_about_license: ['许可与详情', '授權與詳細資訊'],
  profile_data_source: ['数据源', '資料來源'],
  profile_app_version: ['应用版本', '應用程式版本'],
  profile_env: ['运行环境', '執行環境'],
  profile_env_value: ['HarmonyOS %s · API 26', 'HarmonyOS %s · API 26'],
  profile_uid: ['UID: %s', 'UID: %s'],
  profile_settings_accessibility: ['设置：应用偏好、存储管理与高级选项', '設定：應用程式偏好、儲存空間管理與進階選項'],

  // ===== 日常功能入口 =====
  menu_message: ['消息中心', '訊息中心'],
  menu_message_desc: ['评论回复 / 社区回复 / 系统消息', '留言回覆／社群回覆／系統訊息'],
  menu_history: ['阅读历史', '閱讀記錄'],
  menu_history_desc: ['接着上次的进度继续阅读', '從上次的進度繼續閱讀'],
  menu_download: ['下载管理', '下載管理'],
  menu_download_desc: ['离线章节、下载任务与文件清理', '離線章節、下載任務與檔案清理'],
  menu_settings: ['设置', '設定'],

  // ===== 设置页 =====
  settings_title: ['设置', '設定'],
  group_prefs: ['内容与偏好', '內容與偏好'],
  group_storage: ['存储管理', '儲存空間管理'],
  group_appearance: ['显示与外观', '顯示與外觀'],
  group_privacy: ['账户与隐私', '帳戶與隱私'],
  group_advanced: ['高级', '進階'],
  unavailable: ['暂未支持', '尚未支援'],

  settings_rating_title: ['内容类型', '內容類型'],
  settings_rating_desc: ['选择要显示的内容类型', '選擇要顯示的內容類型'],
  rating_all_ages: ['仅全年龄内容', '僅全年齡內容'],
  rating_adult: ['仅限值级内容', '僅限分級內容'],
  rating_all: ['显示全部内容', '顯示全部內容'],
  settings_rating_hint: ['修改后立即生效，同步至所有请求；阅读方向请在阅读器内调整',
    '修改後立即生效，同步至所有請求；閱讀方向請在閱讀器內調整'],

  settings_language: ['应用语言', '應用程式語言'],
  lang_system: ['系统默认', '系統預設'],
  lang_zh_cn: ['简体中文', '簡體中文'],
  lang_zh_tw: ['繁体中文', '繁體中文'],
  settings_language_hint: ['语言修改后需重新启动应用才会生效', '語言修改後需重新啟動應用程式才會生效'],
  toast_lang_saved: ['语言设置已保存，应用将在下次重新启动后使用新语言。',
    '語言設定已儲存，應用程式將於下次重新啟動後使用新語言。'],
  toast_lang_system: ['已设置为跟随系统语言，下次重新启动应用后生效。',
    '已設定為跟隨系統語言，下次重新啟動應用程式後生效。'],
  toast_lang_failed: ['语言设置失败，已保留原设置', '語言設定失敗，已保留原設定'],

  settings_server: ['切换服务器分流', '切換伺服器分流'],
  settings_server_reason: ['当前仅有单一官方入口（noymanga.com），无经过验证的备用节点',
    '目前僅有單一官方入口（noymanga.com），沒有經過驗證的備用節點'],
  settings_block_tags: ['屏蔽标签', '封鎖標籤'],
  settings_block_tags_desc: ['按标签过滤首页、榜单、搜索与推荐；仅本机保存',
    '依標籤過濾首頁、榜單、搜尋與推薦；僅本機儲存'],

  storage_cache: ['图片缓存', '圖片快取'],
  storage_cache_desc: ['阅读器临时缓存图片，清理不影响离线章节', '閱讀器暫存圖片，清理不影響離線章節'],
  storage_cache_clear: ['清理图片缓存', '清理圖片快取'],
  storage_cache_clearing: ['清理中...', '清理中...'],
  storage_offline: ['离线数据', '離線資料'],
  storage_offline_desc: ['下载文件和离线章节，与图片缓存分开统计',
    '下載檔案與離線章節，與圖片快取分開統計'],
  storage_offline_manage: ['前往下载管理 →', '前往下載管理 →'],
  storage_calc: ['统计中...', '統計中...'],
  storage_failed: ['统计失败', '統計失敗'],

  settings_time_format: ['时间格式化', '時間格式'],
  time_abs: ['绝对时间', '絕對時間'],
  time_rel: ['相对时间', '相對時間'],
  toast_time_format_partial: ['时间格式已切换，但可能未保存到本地', '時間格式已切換，但可能未儲存到本機'],

  settings_theme: ['主题设置', '主題設定'],
  theme_system: ['跟随系统', '跟隨系統'],
  theme_light: ['浅色模式', '淺色模式'],
  theme_dark: ['深色模式', '深色模式'],
  settings_theme_hint: ['跟随系统会根据设备当前的显示模式自动切换。',
    '跟隨系統會依裝置目前的顯示模式自動切換。'],
  toast_theme_saved: ['主题已切换', '主題已切換'],
  toast_theme_failed: ['主题切换失败，已恢复原设置', '主題切換失敗，已還原原設定'],

  settings_privacy: ['隐私设定', '隱私設定'],
  settings_privacy_reason: ['服务端未提供资料/评论可见性配置接口（API 未验证）',
    '伺服器未提供資料／留言可見性設定介面（API 未驗證）'],
  adv_report: ['错误报告', '錯誤回報'],
  adv_report_desc: ['查看本应用记录的异常日志，可导出脱敏文件',
    '檢視本應用程式記錄的異常日誌，可匯出脫敏檔案'],
  adv_log: ['网络日志', '網路日誌'],
  adv_log_desc: ['查看本应用请求的路径、状态与耗时，可导出',
    '檢視本應用程式請求的路徑、狀態與耗時，可匯出'],
  adv_cache: ['高级缓存配置', '進階快取設定'],
  adv_cache_desc: ['容量上限与按最近访问时间自动清理',
    '容量上限與依最近存取時間自動清理'],

  // ===== 弹窗与通用 =====
  dialog_logout_title: ['退出登录', '登出'],
  dialog_logout_body: ['将吊销服务端会话并清除本机登录状态。本地收藏、下载、阅读历史与设置不受影响。',
    '將撤銷伺服器工作階段並清除本機登入狀態。本機收藏、下載、閱讀記錄與設定不受影響。'],
  dialog_logout_confirm: ['退出', '登出'],
  dialog_clear_cache_title: ['清理图片缓存', '清理圖片快取'],
  dialog_clear_cache_body: ['将删除约 %s 的图片缓存，书籍收藏、阅读进度与离线章节不受影响。',
    '將刪除約 %s 的圖片快取，書籍收藏、閱讀進度與離線章節不受影響。'],
  dialog_clear_confirm: ['清理', '清理'],
  common_cancel: ['取消', '取消'],
  common_back: ['返回', '返回'],
  common_retry: ['重试', '重試'],
  common_confirm: ['确定', '確定'],
  toast_logout_done: ['已退出登录', '已登出'],
  toast_logout_failed: ['登出失败，请重试', '登出失敗，請重試'],
  toast_cache_freed: ['已清理 %s', '已清理 %s'],
  toast_cache_partial: ['已清理 %s，%d 个文件未能删除', '已清理 %s，%d 個檔案未能刪除'],
  toast_cache_empty: ['缓存已经是空的', '快取已經是空的'],
  toast_cache_failed: ['清理失败，请稍后重试', '清理失敗，請稍後重試'],

  // ===== 时间（相对时间） =====
  time_just_now: ['刚刚', '剛剛'],
  time_minutes_ago: ['%d 分钟前', '%d 分鐘前'],
  time_hours_ago: ['%d 小时前', '%d 小時前'],
  time_days_ago: ['%d 天前', '%d 天前'],

  // ===== 关于页 =====
  about_desc: ['NoyAcg 的 HarmonyOS 原生客户端：纯 ArkTS + ArkUI（Stage 模型），不含 WebView 套壳。',
    'NoyAcg 的 HarmonyOS 原生用戶端：純 ArkTS + ArkUI（Stage 模型），不含 WebView 外殼。'],
  about_uid: ['当前 UID', '目前 UID'],
  about_license: ['开源许可', '開源授權'],
  about_license_body: ['本项目使用的第三方组件（HarmonyOS SDK、hypium 等）遵循其各自的开源许可；项目自身的许可信息以代码仓库附带的许可文件为准。',
    '本專案使用的第三方元件（HarmonyOS SDK、hypium 等）遵循其各自的開源授權；專案本身的授權資訊以程式碼倉庫附帶的授權文件為準。'],

  // ===== 内容发现 / 分页（Phase 14-N） =====
  discovery_rank: ['排行榜', '排行榜'],
  discovery_category: ['分类', '分類'],
  discovery_personalized: ['个人化精选', '個人化精選'],

  pagination_total: ['总量：%d', '總量：%d'],
  pagination_pages: ['页数：%d', '頁數：%d'],
  // 14-N1：本地已获取数量与本地页数，明确区别于服务端全局总量
  pagination_loaded: ['已获取：%d 条', '已取得：%d 筆'],
  pagination_local_pages: ['本地页数：%d', '本機頁數：%d'],
  pagination_unknown: ['总量未知', '總量未知'],
  pagination_jump: ['转到', '轉到'],
  pagination_prev: ['上一页', '上一頁'],
  pagination_next: ['下一页', '下一頁'],
  pagination_jump_title: ['跳转到指定页', '跳轉到指定頁'],
  pagination_jump_placeholder: ['输入页码', '輸入頁碼'],
  pagination_jump_confirm: ['跳转', '跳轉'],
  pagination_jump_invalid: ['请输入正整数页码', '請輸入正整數頁碼'],
  pagination_jump_range: ['页码需在 1 - %d 之间', '頁碼需在 1 - %d 之間'],

  // ===== 排行榜（Phase 14-Q：官方 readLeaderboard / favLeaderboard / proportion） =====
  rank_title: ['排行榜', '排行榜'],
  rank_reading: ['阅读榜', '閱讀榜'],
  rank_favorite: ['收藏榜', '收藏榜'],
  rank_high_quality: ['高质量榜', '高品質榜'],
  rank_day: ['日榜', '日榜'],
  rank_week: ['周榜', '週榜'],
  rank_month: ['月榜', '月榜'],
  rank_source_note: ['数据来自官方榜单接口，按服务端返回顺序展示', '資料來自官方榜單介面，依伺服器回傳順序展示'],
  rank_empty: ['暂无榜单数据', '暫無榜單資料'],
  rank_empty_desc: ['服务端当前未返回该榜单内容', '伺服器目前未回傳該榜單內容'],

  category_title: ['分类', '分類'],
  category_empty: ['暂无分类', '暫無分類'],
  category_empty_desc: ['分类目录未能加载', '分類目錄未能載入'],
  // Phase 14-Q：服务端返回空目录（与「加载失败」区分）
  category_empty_hint: ['服务端暂未返回分类', '伺服器暫未回傳分類'],
  category_placeholder: ['占位图', '佔位圖'],
  category_fantasy: ['奇幻', '奇幻'],
  category_romance: ['恋爱', '戀愛'],
  category_daily: ['日常', '日常'],
  category_comedy: ['搞笑', '搞笑'],
  category_hotblood: ['热血', '熱血'],
  category_action: ['动作', '動作'],
  category_mystery: ['悬疑', '懸疑'],
  category_healing: ['治愈', '治癒'],
  category_school: ['校园', '校園'],
  category_music: ['音乐', '音樂'],
  category_four_panel: ['四格', '四格'],
  category_yuri: ['百合', '百合'],
  category_tag_fantasy: ['奇幻', '奇幻'],
  category_tag_romance: ['戀愛', '戀愛'],
  category_tag_daily: ['日常', '日常'],
  category_tag_comedy: ['搞笑', '搞笑'],
  category_tag_hotblood: ['熱血', '熱血'],
  category_tag_action: ['動作', '動作'],
  category_tag_mystery: ['懸疑', '懸疑'],
  category_tag_healing: ['治癒', '治癒'],
  category_tag_school: ['校園', '校園'],
  category_tag_music: ['音樂', '音樂'],
  category_tag_four_panel: ['四格', '四格'],
  category_tag_yuri: ['百合', '百合'],

  // ===== 个人化精选（Phase 14-Q：官方 favoritesrecommend） =====
  personalized_title: ['个人化精选', '個人化精選'],
  recommend_empty_title: ['暂无推荐', '暫無推薦'],
  recommend_empty_desc: ['多收藏一些作品后再来看看吧', '多收藏一些作品後再來看看吧'],

  // ===== 首页区块标题（与官方 Web 首页命名一致） =====
  home_section_read_rank: ['今日阅读榜', '今日閱讀榜'],
  home_section_fav_rank: ['今日收藏榜', '今日收藏榜'],
  home_section_recommend: ['收藏推荐', '收藏推薦'],
  home_section_quality: ['高质榜', '高質榜'],

  // ===== 屏蔽标签（Phase 14-R） =====
  blocked_scope_local: ['作用范围：本机（未登录）', '作用範圍：本機（未登入）'],
  blocked_scope_account: ['作用范围：本机 · 当前账号', '作用範圍：本機 · 目前帳號'],
  blocked_scope_note: ['屏蔽规则只保存在本机，不会同步到其他设备；切换账号后自动切换到该账号的配置。',
    '封鎖規則只儲存在本機，不會同步到其他裝置；切換帳號後自動切換到該帳號的設定。'],
  blocked_empty: ['暂无屏蔽标签', '暫無封鎖標籤'],
  blocked_empty_desc: ['加入标签后，含该标签的内容会从首页、榜单、搜索与推荐中隐藏。',
    '加入標籤後，含該標籤的內容會從首頁、榜單、搜尋與推薦中隱藏。'],
  blocked_add_placeholder: ['输入完整标签名称', '輸入完整標籤名稱'],
  blocked_add: ['添加标签', '新增標籤'],
  blocked_remove: ['移除', '移除'],
  blocked_clear: ['清空屏蔽标签', '清空封鎖標籤'],
  blocked_clear_confirm: ['将移除全部屏蔽标签，被过滤的内容会重新出现在列表里。',
    '將移除全部封鎖標籤，被過濾的內容會重新出現在列表中。'],
  blocked_invalid: ['请输入完整标签名称（不超过 40 个字符）', '請輸入完整標籤名稱（不超過 40 個字元）'],
  blocked_limit: ['最多只能屏蔽 %d 个标签', '最多只能封鎖 %d 個標籤'],
  blocked_save_failed: ['已生效，但未能保存到本地', '已生效，但未能儲存到本機'],

  // ===== 缓存策略（Phase 14-R） =====
  cache_usage_title: ['当前占用', '目前佔用'],
  cache_limit_title: ['容量上限', '容量上限'],
  cache_limit_desc: ['超出上限时按最近访问时间自动清理最旧的图片缓存。',
    '超出上限時依最近存取時間自動清理最舊的圖片快取。'],
  cache_limit_mb500: ['500 MB', '500 MB'],
  cache_limit_gb1: ['1 GB', '1 GB'],
  cache_limit_unlimited: ['无限制', '無限制'],
  cache_lru_note: ['清理顺序：最久未访问的图片优先删除，单次清理回到上限的 90%，避免频繁抖动。',
    '清理順序：最久未存取的圖片優先刪除，單次清理回到上限的 90%，避免頻繁抖動。'],
  cache_offline_isolated: ['离线章节与下载文件存放在独立目录，不受缓存清理影响。',
    '離線章節與下載檔案存放在獨立目錄，不受快取清理影響。'],
  cache_clean_now: ['立即检查容量', '立即檢查容量'],
  cache_clean_never: ['本次会话尚未执行自动清理', '本次工作階段尚未執行自動清理'],
  cache_clean_result: ['已清理 %d 个文件，释放 %s', '已清理 %d 個檔案，釋放 %s'],
  cache_over_limit: ['当前占用已超出上限，将在下次检查时自动清理',
    '目前佔用已超出上限，將於下次檢查時自動清理'],
  cache_limit_save_failed: ['容量上限未能保存到本地', '容量上限未能儲存到本機'],
  dialog_clear_cache_body_short: ['只删除图片缓存，离线章节、收藏与阅读进度不受影响。',
    '只刪除圖片快取，離線章節、收藏與閱讀進度不受影響。'],

  // ===== 诊断日志（Phase 14-R） =====
  diag_filter_all: ['全部', '全部'],
  diag_filter_error: ['错误', '錯誤'],
  diag_filter_warn: ['警告', '警告'],
  diag_capability_note: ['仅收集本应用记录的异常与 ArkTS 未捕获异常；Native 崩溃与系统级故障仍需系统日志。日志已脱敏，不自动上传。',
    '僅收集本應用程式記錄的異常與 ArkTS 未捕獲異常；Native 崩潰與系統級故障仍需系統日誌。日誌已脫敏，不自動上傳。'],
  diag_export: ['导出日志', '匯出日誌'],
  diag_export_ok: ['已导出到 %s', '已匯出到 %s'],
  diag_export_failed: ['导出失败，请稍后重试', '匯出失敗，請稍後重試'],
  diag_clear: ['清空日志', '清空日誌'],
  diag_clear_confirm: ['清空后无法恢复，确定继续？', '清空後無法復原，確定繼續？'],
  diag_empty: ['暂无错误日志', '暫無錯誤日誌'],
  diag_empty_desc: ['当前没有记录到错误或警告。', '目前沒有記錄到錯誤或警告。'],

  // ===== 网络日志（Phase 14-R） =====
  net_filter_all: ['全部', '全部'],
  net_filter_error: ['失败', '失敗'],
  net_filter_ok: ['成功', '成功'],
  net_search_hint: ['按接口路径搜索', '依介面路徑搜尋'],
  net_privacy_note: ['只记录本应用发出的请求元数据（路径、状态、耗时）；不含 Cookie、Token 与正文，不做抓包。',
    '只記錄本應用程式發出的請求中繼資料（路徑、狀態、耗時）；不含 Cookie、Token 與內容，不做封包擷取。'],
  net_export: ['导出日志', '匯出日誌'],
  net_export_ok: ['已导出到 %s', '已匯出到 %s'],
  net_export_failed: ['导出失败，请稍后重试', '匯出失敗，請稍後重試'],
  net_clear: ['清空日志', '清空日誌'],
  net_clear_confirm: ['清空后无法恢复，确定继续？', '清空後無法復原，確定繼續？'],
  net_empty: ['暂无请求记录', '暫無請求記錄'],
  net_empty_desc: ['打开首页或刷新列表后会自动出现。', '開啟首頁或重新整理列表後會自動出現。'],

  // ===== 封面角标（Phase 14-S） =====
  // 状态角标：只在协议层确认 status 后才出现，未知状态不显示
  badge_status_completed: ['已完结', '已完結'],
  badge_status_ongoing: ['连载中', '連載中'],
  // 关键词角标：只来自漫画自身真实标签（服务端 Ptag/Otag）
  badge_kw_kinky: ['重口', '重口'],
  badge_kw_ntr: ['NTR', 'NTR'],
  badge_kw_uncle: ['大叔', '大叔'],

  // ===== 状态视图 =====
  state_empty_default: ['暂无内容', '暫無內容'],
  state_error_default: ['加载失败', '載入失敗']
};

/** 生成 HarmonyOS 资源文件结构：index 0 = 简体，1 = 繁体 */
function build(index) {
  const list = Object.keys(DICT).map((name) => ({ name, value: DICT[name][index] }));
  return JSON.stringify({ string: list }, null, 2) + '\n';
}

const root = join('entry', 'src', 'main', 'resources');
const targets = [
  { dir: 'base', index: 0 },
  { dir: 'zh_CN', index: 0 },
  { dir: 'zh_TW', index: 1 }
];

for (const t of targets) {
  const path = join(root, t.dir, 'element', 'string.json');
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, build(t.index), 'utf8');
  console.log(`written: ${path} (${Object.keys(DICT).length} keys)`);
}
