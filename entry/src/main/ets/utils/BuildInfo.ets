/**
 * BuildInfo.ets —— 构建身份与构建模式门控（I-000005 / I-000012）
 *
 * 作用：
 * 1. BUILD_ID 同时出现在启动日志（hilog：[Build] id=...）与「关于」页；
 * 2. IS_DEBUG_BUILD 由 Hvigor 生成的 BuildProfile（BUILD_MODE_NAME / DEBUG）动态派生，
 *    Release 构建下严格为 false，消除人工常量误置风险（I-000012）。
 */
import BuildProfile from 'BuildProfile';

export const BUILD_ID: string = 'NoyACG-R6.1-DEVICE-05';

/** 只有 buildModeName === 'debug' 且 debugFlag === true 时才允许开启调试构建门控 */
export function resolveIsDebugBuild(buildModeName: string, debugFlag: boolean): boolean {
  return buildModeName === 'debug' && debugFlag === true;
}

/**
 * 是否为 debug 构建（I-000005 / I-000012）。
 * 唯一事实来源：HttpManager.diagnosticEnabled() 读取它；Release 模式下严格为 false。
 */
export const IS_DEBUG_BUILD: boolean =
  resolveIsDebugBuild(BuildProfile.BUILD_MODE_NAME, BuildProfile.DEBUG);

/**
 * 调试戳开关（仅允许在 debug 构建且显式启用时展示；生产发布恒为 false）。
 */
export const DEBUG_STAMP_ENABLED: boolean = false;
