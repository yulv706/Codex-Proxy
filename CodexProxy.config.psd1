@{
    SchemaVersion              = 2
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
    ShortcutDescription        = '通过本地代理启动 OpenAI Codex'
    InstallPath                = 'CodexProxy'
    HelperCachePath            = 'OpenAI\Codex\bin\codex-proxy-current'
    LogPath                    = 'CodexProxy\logs\launcher.log'
    LogMaxBytes                = 1048576
    LogRetention               = 3
    RequireValidSignatures     = $true
}
