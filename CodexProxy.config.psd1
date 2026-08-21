@{
    SchemaVersion              = 3
    ProxyHost                  = '127.0.0.1'
    ProxyPort                  = 7891
    ProxyProbeHost             = 'api.openai.com'
    ProxyProbePort             = 443
    ProxyConnectTimeoutSeconds = 5
    LaunchTimeoutSeconds       = 15
    PackageName                = 'OpenAI.Codex'
    ExpectedPublisherId        = '2p2nqsd0c76g0'
    AppId                      = 'App'
    ShortcutName               = 'Codex-Proxy.lnk'
    UpdateShortcutName         = 'Codex-Proxy 更新.lnk'
    ShortcutDescription        = '通过本地代理启动 OpenAI Codex'
    InstallPath                = 'CodexProxy'
    HelperCachePath            = 'OpenAI\Codex\bin\codex-proxy-current'
    LogPath                    = 'CodexProxy\logs\launcher.log'
    LogMaxBytes                = 1048576
    LogRetention               = 3
    RequireValidSignatures     = $true
    UpdateX64Uri               = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
    UpdateArm64Uri             = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix'
    UpdateStoreProductId       = '9PLM9XGG6VKS'
    UpdateDownloadTimeoutSeconds = 1800
}
