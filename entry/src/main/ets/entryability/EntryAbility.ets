/**
 * EntryAbility.ets —— 应用入口 UIAbility（Stage 模型）
 *
 * 职责：
 * 1. onCreate：注入全局单例上下文（图片缓存 cacheDir / 安全区查询 /
 *    数据库初始化），全部异步非阻塞；
 * 2. onWindowStageCreate：首帧前完成沉浸式配置，再加载首页；
 * 3. onDestroy：释放数据库句柄与 rcp 会话（收官战硬性要求：句柄安全释放）。
 */
import { AbilityConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { DatabaseManager } from '../utils/DatabaseManager';
import { PreferenceManager } from '../utils/PreferenceManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeManager } from '../utils/ThemeManager';
import { Configuration } from '@kit.AbilityKit';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { AuthManager } from '../utils/AuthManager';
import { HttpManager } from '../api/HttpManager';
import { DownloadFactory } from '../download/DownloadFactory';
import { DiagnosticLogManager, LOG_LEVEL_ERROR } from '../utils/DiagnosticLogManager';
import { NetworkLogManager } from '../utils/NetworkLogManager';
import { RequestGate } from '../api/RequestGate';
import { NetworkMonitor } from '../api/NetworkMonitor';
import { BUILD_ID } from '../utils/BuildInfo';
import { ViewportState } from '../utils/ViewportState';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {

  /**
   * 当前 WindowStage（Phase 15-R2.1 P0-02）。
   * 重绑主窗口时必须用它 `getMainWindowSync()`，而不是 `window.getLastWindow()`：
   * 后者在存在弹窗 / 子窗口时会取到别的窗口，几何与避让都会读错。
   */
  private mainWindowStage?: window.WindowStage;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, `onCreate, action=${want.action ?? ''}`);
    // 提前注入应用级上下文：图片缓存（cacheDir）与安全区查询（主窗口）全局复用，
    // 同时规避组件 aboutToAppear 中获取 UI 上下文的时序风险
    ImageCacheManager.getInstance().init(this.context);
    // Phase 14-M：主题需要 context 读系统深浅色
    ThemeManager.getInstance().init(this.context);
    // Phase 14-L：本地化入口需要 context 才能取字符串资源
    LocalizationManager.getInstance().init(this.context);
    SafeAreaManager.init(this.context);
    // 数据库初始化（建库建表）：异步执行不阻塞启动，内部幂等去重；
    // 首个数据库调用会通过 ensureReady 自动等待其完成
    DatabaseManager.getInstance().init(this.context);
    // 偏好设置初始化（阅读方向 / 搜索历史 / 内容分级）：全局唯一注入点，
    // 页面侧只读内存快照，严禁在多个页面各自初始化 Preferences。
    // Phase 14-J1：内容分级全局策略须在偏好「载入完成后」再读取持久化值，
    // 否则读到默认值而非用户上次选择（init 内部已吞掉失败，这里只需 then）。
    PreferenceManager.getInstance().init(this.context).then((): void => {
      ContentRatingPolicy.getInstance().loadFromPreference();
      // Phase 14-M：主题模式在偏好载入后恢复（先于首帧渲染，避免深→浅闪一下）
      ThemeManager.getInstance().restore(
        PreferenceManager.getInstance().getThemeModeSync(),
        PreferenceManager.getInstance().getThemeAccentSync()
      );
      LocalizationManager.getInstance().restorePreferred(
        PreferenceManager.getInstance().getAppLanguageSync()
      );
    }).catch((): void => {
      // 偏好初始化失败：保持默认全年龄，不阻断启动
    });
    // 认证会话恢复：非阻塞触发（有 Cookie 才会请求 /v3/userinfo 校验），
    // 绝不阻塞首帧；校验结果通过 @Trace 状态驱动 UI
    AuthManager.getInstance().initialize();
    // Phase 12：下载子系统一次性装配（幂等，不在每次进页面时重建）。
    // 永久下载目录在 filesDir/Downloads，与 cacheDir 的临时图片缓存严格隔离。
    DownloadFactory.init(this.context);
    // Phase 14-R：诊断 / 网络日志目录（filesDir/diagnostics，与图片缓存严格分离）
    DiagnosticLogManager.getInstance().init(this.context);
    NetworkLogManager.getInstance().init(this.context);
    // I-000004：系统断网订阅（幂等；无网络能力环境内部降级乐观在线，由 GET 重试兜底）
    NetworkMonitor.getInstance().start();
    this.installErrorObserver();
    // Phase 14-R：启动后一次轻量容量检查（异步，不阻塞首帧；内部单飞 + 有界删除）
    ImageCacheManager.getInstance().enforceCacheLimitInBackground();
  }

  /**
   * ArkTS 未捕获异常 / Promise 未处理拒绝 → 应用内诊断日志（Phase 14-R）。
   * 能力边界：这里只能捕获 JS/ArkTS 层异常；Native 进程崩溃仍需系统故障日志。
   * 注册失败不影响启动（部分环境可能不支持该回调）。
   */
  private installErrorObserver(): void {
    try {
      const observer: DiagnosticErrorObserver = new DiagnosticErrorObserver();
      errorManager.on('error', observer as errorManager.ErrorObserver);
      Logger.info(TAG, 'ArkTS 未捕获异常观察器已注册');
    } catch (e) {
      Logger.warn(TAG, `异常观察器注册失败: ${(e as BusinessError).message}`);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(TAG, 'onWindowStageCreate');
    // ★ 构建身份：设备日志里出现这一行，才能证明跑的是这一版源码（R2-6）
    //   只取 bundleName（applicationInfo 无 versionName 字段，版本号见「关于」页）
    Logger.info('Build', `BUILD_ID=${BUILD_ID} bundle=${this.context.applicationInfo.name}`);

    // 沉浸式配置必须在 loadContent 之前完成，避免首帧出现系统栏色块闪烁
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      // 主题切换时同步系统栏图标颜色（白图标只适用于深色底）
      ThemeManager.getInstance().setSystemBarApplier((isDark: boolean): void => {
        EntryAbility.applySystemBars(mainWindow, isDark);
      });
      this.enterImmersiveMode(mainWindow);
      // ★ 根窗口几何采样（导航形态唯一输入）：先登记 Stage 再绑定窗口，采样早于首帧
      this.mainWindowStage = windowStage;
      SafeAreaManager.attachWindowStage(windowStage);
      SafeAreaManager.bindMainWindow(mainWindow);
      Logger.info(TAG, `窗口就绪 navMode=${ViewportState.getInstance().navMode} ` +
        `${ViewportState.getInstance().geometryHint()}`);
    } catch (e) {
      Logger.error(TAG, `获取主窗口失败: ${(e as BusinessError).message}`);
    }

    // 加载首页（pages/Index 需在 resources/base/profile/main_pages.json 中注册）
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(TAG, `loadContent 失败: ${err.code} - ${err.message}`);
        return;
      }
      Logger.info(TAG, '首页加载完成');
    });
  }

  /**
   * 沉浸式（全屏体验）配置：
   * 1. setWindowLayoutFullScreen(true)：页面内容延伸绘制到状态栏 / 三键导航栏之下；
   * 2. setWindowSystemBarProperties：系统栏完全透明 + 图标颜色跟随当前主题。
   *
   * ★ 系统栏图标颜色（Phase 15-R2 修正注释）：图标颜色不是恒为白色。
   *   本工程自 Phase 14-M 起有深 / 浅两套调色板，`applySystemBars` 用
   *   `ThemeManager.isDark` 决定 `isStatusBarLightIcon`：
   *   深色主题 → 浅色（白）图标；浅色主题 → 深色图标。
   *   启动窗口底色由 module.json5 的 `startWindowBackground = $color:start_window_background`
   *   声明，避免首帧出现与主题相反的底色。
   *   （注：window.setWindowBackgroundColor 在本工程支持的设备类型上不可用，
   *     已改用上面的资源声明方式，避免引入「API unavailable」警告。）
   */
  private enterImmersiveMode(mainWindow: window.Window): void {
    mainWindow.setWindowLayoutFullScreen(true)
      .then((): void => {
        EntryAbility.applySystemBars(mainWindow, ThemeManager.getInstance().isDark);
        Logger.info(TAG, '沉浸式配置完成');
      })
      .catch((err: BusinessError): void => {
        Logger.error(TAG, `沉浸式配置失败: ${err.code} - ${err.message}`);
      });
  }

  /**
   * 系统栏（状态栏 + 导航栏）配色：透明底 + 图标颜色跟随主题。
   * - 深色主题：浅色（白）图标；
   * - 浅色主题：深色图标。
   * 这是 ThemeManager 通过 setSystemBarApplier 回调的唯一窗口级落点，
   * 保证「切换主题后状态栏图标仍可读」，而不是只改页面背景。
   */
  private static applySystemBars(win: window.Window, isDark: boolean): void {
    const barProps: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      isStatusBarLightIcon: isDark,
      isNavigationBarLightIcon: isDark
    };
    win.setWindowSystemBarProperties(barProps).catch((err: BusinessError): void => {
      Logger.warn(TAG, `系统栏配色失败: ${err.code} - ${err.message}`);
    });
  }

  /** 系统深浅色切换（跟随系统模式下需要重新解析调色板） */
  onConfigurationUpdate(newConfig: Configuration): void {
    Logger.info(TAG, `配置更新: colorMode=${newConfig.colorMode}`);
    ThemeManager.getInstance().onSystemColorModeChanged();
    // 配置变更（含显示大小 / 深色模式 / 语言）后安全区与密度都可能变，缓存必须失效并重采样。
    // 折叠/分屏可能换 Window 实例：先按对象身份检查是否需要重绑，再采样（P0-02）。
    SafeAreaManager.invalidateMetrics();
    SafeAreaManager.rebindMainWindowIfNeeded(this.mainWindowStage);
  }

  onForeground(): void {
    Logger.info(TAG, 'onForeground');
    // 回到前台重采样一次：后台期间可能发生折叠 / 分屏 / 分辨率变化。
    // 实例未变时不重复注册监听，只刷新几何；变了则先解绑旧窗口再绑新窗口（P0-02）。
    SafeAreaManager.rebindMainWindowIfNeeded(this.mainWindowStage);
    // I-000004：回到前台 → 闸门可见（此前不可见时等待中的 GET 在此放行）
    RequestGate.getInstance().setAppVisible(true);
    // Phase 14-T1：应用回到前台时做一次分级一致性检查。
    // 后台期间分级通常不会被改（唯一写入入口是设置页），但这里兜底：
    // 若持久化值与内存态不一致，就广播变更，让仍存活的前台页面按新分级重新请求。
    // 未变化时是廉价的空操作，不会触发任何网络请求。
    try {
      ContentRatingPolicy.getInstance().reconcileFromPreference();
    } catch (e) {
      Logger.warn(TAG, `前台分级一致性检查失败: ${(e as BusinessError).message}`);
    }
  }

  onBackground(): void {
    Logger.info(TAG, 'onBackground');
    // I-000004：切入后台 → 闸门不可见（新请求不抢跑，等待前台再放行）
    RequestGate.getInstance().setAppVisible(false);
  }

  onDestroy(): void {
    Logger.info(TAG, 'onDestroy');
    // ★ 句柄安全释放：数据库连接 + rcp 网络会话
    DatabaseManager.getInstance().close();
    HttpManager.getInstance().destroy();
    // Phase 12：停止下载调度并取消在途 RCP 请求；任务状态保留，
    // 下次启动由 DownloadRepository.recover() 归位为可恢复状态
    DownloadFactory.shutdown();
    // I-000004：停止系统断网订阅（应用退出）
    NetworkMonitor.getInstance().stop();
  }
}

/**
 * 异常观察器实现（Phase 14-R）。
 * 只做「脱敏后写入诊断日志」，不尝试恢复、不吞掉崩溃流程。
 */
class DiagnosticErrorObserver {
  onUnhandledException(errMsg: string): void {
    DiagnosticLogManager.getInstance().record(LOG_LEVEL_ERROR, 'UncaughtException', errMsg);
  }

  onException(errObject: Error): void {
    DiagnosticLogManager.getInstance().recordException('UncaughtException', errObject);
  }
}
