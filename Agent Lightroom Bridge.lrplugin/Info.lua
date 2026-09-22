return {
    LrSdkMinimumVersion = 6.0,
    LrSdkVersion = 13.0,
    LrToolkitIdentifier = 'com.agentlightroom.bridge',
    LrPluginName = 'Agent Lightroom Bridge',
    LrInitPlugin = 'Bridge.lua',
    VERSION = { major = 0, minor = 2, revision = 0 },
    -- 图库模块菜单项：出现在「文件 → 增效工具额外信息」下。
    -- LrInitPlugin 在 LR 重启后并不会被重复执行，因此提供一个可被外部
    -- （osascript / dsh-cua 点击菜单栏）主动触发的入口来启动桥接轮询。
    LrLibraryMenuItems = {
        {
            title = 'Agent Lightroom: Start Bridge',
            file = 'Bridge.lua',
        },
    },
    -- ⚠️ 2026-09-19 实锤 bug：下面这项原本写成了**单个表**
    --     LrExportMenuItems = { title = ..., file = ... }
    --   LR 期望的是**数组**（{ { title=..., file=... } }），因此这一项**从未注册成功**——
    --   表现为「文件 → 增效工具额外信息」里只有别的插件的项（实测只有 ON1），
    --   而外部靠菜单点击来重载插件的自动化会**静默失败**（点空），
    --   再叠加「验证 ping 被上一代旧循环应答」，就成了极难定位的假成功。
    LrExportMenuItems = {
        {
            title = 'Agent Lightroom - Start Bridge',
            file = 'Bridge.lua',
        },
    },
}
