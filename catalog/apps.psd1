@{
    # Catalog contract (schema version 1.1.0)
    #
    # Required application fields:
    #   Key, Name, Order, InstallOrder, InstallPhase, InstallerType,
    #   RequiresNetwork, ProxyPolicy, Detection, VersionPolicy,
    #   ManualActions, and Safety.
    #
    # InstallerType values:
    #   Winget       - install from the community WinGet source.
    #   Store        - install from the Microsoft Store WinGet source.
    #   ManualOrSeed - never execute until immutable seed metadata is reviewed.
    #   Wsl          - enable Windows features and install a WSL distribution.
    #
    # Detection values are hints consumed together: uninstall display-name
    # patterns, command names, AppX names, service names, and WSL state. An
    # empty array means that detector is not applicable; it is not a wildcard.
    #
    # Safety.Ready is authoritative. A false value must fail closed with
    # Safety.FailureStatus even if other installer fields appear usable.
    # Lifecycle.State = Deprecated keeps a compatibility key valid for
    # explicit selection while excluding it from the default menu.

    SchemaVersion = '1.1.0'

    MirrorHosts = @(
        'ghfast.top'
        'gh-proxy.com'
    )

    Applications = @(
        @{
            Key             = 'chrome'
            Name            = 'Google Chrome'
            Order           = 1
            InstallOrder    = 100
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Google.Chrome'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Google Chrome*')
                Commands            = @('chrome.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'clash-verge-rev'
            Name            = 'Clash Verge Rev'
            Order           = 2
            InstallOrder    = 10
            InstallPhase    = 'ProxyBootstrap'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'ClashVergeRev.ClashVergeRev'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Clash Verge Rev*', 'Clash Verge*')
                Commands            = @('clash-verge.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @(
                'Add a trusted subscription in Clash Verge Rev, start the proxy, verify HTTPS connectivity, and rerun this bootstrapper.'
            )
            Safety          = @{
                Ready                       = $true
                FailureStatus               = ''
                FailureReason               = ''
                DirectFallbackReady         = $false
                DirectFallbackFailureReason = 'No approved immutable installer URL, SHA-256, and Authenticode signer are cataloged.'
            }
        }

        @{
            Key             = 'xftp'
            Name            = 'Xftp 8 Home/School'
            Order           = 3
            InstallOrder    = 110
            InstallPhase    = 'Standard'
            InstallerType   = 'ManualOrSeed'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = ''
            WingetSource    = ''
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Xftp 8*', 'Xftp*')
                Commands            = @('Xftp.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = '8'
                AllowedMajor         = '8'
                RejectMajorAtOrAbove = ''
            }
            Seed             = @{
                FileName     = ''
                Sha256       = ''
                SignerSubject = ''
                SilentArgs   = @()
            }
            ManualActions   = @(
                'Confirm that Home/School licensing applies, obtain Xftp 8 from the official NetSarang channel, and install it manually.'
            )
            Safety          = @{
                Ready         = $false
                FailureStatus = 'ManualActionRequired'
                FailureReason = 'No immutable installer filename, SHA-256, and Authenticode signer have been reviewed for the Home/School package.'
            }
        }

        @{
            Key             = 'xshell'
            Name            = 'Xshell 8 Home/School'
            Order           = 4
            InstallOrder    = 120
            InstallPhase    = 'Standard'
            InstallerType   = 'ManualOrSeed'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = ''
            WingetSource    = ''
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Xshell 8*', 'Xshell*')
                Commands            = @('Xshell.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = '8'
                AllowedMajor         = '8'
                RejectMajorAtOrAbove = ''
            }
            Seed             = @{
                FileName     = ''
                Sha256       = ''
                SignerSubject = ''
                SilentArgs   = @()
            }
            ManualActions   = @(
                'Confirm that Home/School licensing applies, obtain Xshell 8 from the official NetSarang channel, and install it manually.'
            )
            Safety          = @{
                Ready         = $false
                FailureStatus = 'ManualActionRequired'
                FailureReason = 'No immutable installer filename, SHA-256, and Authenticode signer have been reviewed for the Home/School package.'
            }
        }

        @{
            Key             = 'git'
            Name            = 'Git for Windows'
            Order           = 5
            InstallOrder    = 130
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Git.Git'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Git version *')
                Commands            = @('git.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'codex-desktop'
            Name            = 'ChatGPT with Codex desktop'
            Order           = 6
            InstallOrder    = 140
            InstallPhase    = 'Standard'
            InstallerType   = 'Store'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = '9PLM9XGG6VKS'
            WingetSource    = 'msstore'
            WingetVersion   = ''
            StoreProductId  = '9PLM9XGG6VKS'
            Detection       = @{
                DisplayNamePatterns = @('ChatGPT*')
                Commands            = @()
                AppxNames           = @('OpenAI.Codex')
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @(
                'Sign in to ChatGPT after installation to use Codex desktop features.'
            )
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'vscode'
            Name            = 'Visual Studio Code'
            Order           = 7
            InstallOrder    = 150
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Microsoft.VisualStudioCode'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Microsoft Visual Studio Code*')
                Commands            = @('code.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'intellij-idea'
            Name            = 'IntelliJ IDEA'
            Order           = 8
            InstallOrder    = 160
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'JetBrains.IntelliJIDEA'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('IntelliJ IDEA*')
                Commands            = @('idea64.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @(
                'Sign in with the eligible JetBrains account to activate student Ultimate features.'
            )
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'realvnc-server'
            Name            = 'RealVNC Server 7'
            Order           = 9
            InstallOrder    = 170
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'RealVNC.VNCServer'
            WingetSource    = 'winget'
            WingetVersion   = '7.18.0.14'
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('RealVNC Server*', 'VNC Server*', 'RealVNC Connect*')
                Commands            = @('vncserver.exe')
                AppxNames           = @()
                Services            = @('vncserver')
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'ProtectedMajor'
                TargetVersion        = '7.18.0.14'
                AllowedMajor         = '7'
                RejectMajorAtOrAbove = '8'
            }
            ManualActions   = @(
                'Sign in to RealVNC and complete licensing and server access configuration after installation.'
            )
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'realvnc-viewer'
            Name            = 'RealVNC Classic Viewer 7'
            Order           = 10
            InstallOrder    = 180
            InstallPhase    = 'Standard'
            InstallerType   = 'ManualOrSeed'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'RealVNC.VNCViewer'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('RealVNC Viewer*', 'VNC Viewer*', 'RealVNC Connect*')
                Commands            = @('vncviewer.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'ProtectedMajor'
                TargetVersion        = '7.18.1'
                AllowedMajor         = '7'
                RejectMajorAtOrAbove = '8'
            }
            Seed             = @{
                FileName      = ''
                Sha256        = ''
                SignerSubject = ''
                SilentArgs    = @()
            }
            ManualActions   = @(
                'Obtain RealVNC Classic Viewer 7.18.1 from the official RealVNC portal and install it manually.'
            )
            Safety          = @{
                Ready         = $false
                FailureStatus = 'ManualActionRequired'
                FailureReason = 'The WinGet community source only exposes Classic Viewer 7.15.1.18; no reviewed 7.18.1 seed filename, SHA-256, and signer are cataloged.'
            }
        }

        @{
            Key             = 'netease-cloudmusic'
            Name            = 'NetEase Cloud Music'
            Order           = 11
            InstallOrder    = 190
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'NetEase.CloudMusic'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('NetEase Cloud Music*', 'CloudMusic*')
                Commands            = @('cloudmusic.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'nomachine-client'
            Name            = 'NoMachine Enterprise Client'
            Order           = 12
            InstallOrder    = 200
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'NoMachine.NoMachine.EnterpriseClient'
            WingetSource    = 'winget'
            WingetVersion   = '10.0.59'
            StoreProductId  = ''
            PolicyGuardKeys = @('nomachine')
            Detection       = @{
                DisplayNamePatterns = @('NoMachine Enterprise Client*')
                Commands            = @()
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = '10.0.59'
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'bandizip'
            Name            = 'Bandizip Standard'
            Order           = 13
            InstallOrder    = 210
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Bandisoft.Bandizip'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Bandizip*')
                Commands            = @('Bandizip.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'bing-wallpaper'
            Name            = 'Bing Wallpaper'
            Order           = 14
            InstallOrder    = 220
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Microsoft.BingWallpaper'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Bing Wallpaper*')
                Commands            = @('BingWallpaperApp.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'wsl2-ubuntu'
            Name            = 'WSL 2 with Ubuntu 24.04 LTS'
            Order           = 15
            InstallOrder    = 1000
            InstallPhase    = 'Final'
            InstallerType   = 'Wsl'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = ''
            WingetSource    = ''
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @()
                # wsl.exe is an inbox command on Windows 11 and is not proof
                # that both optional features and Ubuntu 24.04 WSL2 exist.
                Commands            = @()
                AppxNames           = @()
                Services            = @()
                WslDistribution     = 'Ubuntu-24.04'
            }
            WindowsFeatures = @(
                'Microsoft-Windows-Subsystem-Linux'
                'VirtualMachinePlatform'
            )
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = '24.04'
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @(
                'Restart Windows if requested, rerun this bootstrapper, then launch Ubuntu once to create the Linux user.'
            )
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'obsidian'
            Name            = 'Obsidian'
            Order           = 16
            InstallOrder    = 230
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'Obsidian.Obsidian'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('Obsidian*')
                Commands            = @('Obsidian.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'cc-switch'
            Name            = 'CC Switch'
            Order           = 17
            InstallOrder    = 240
            InstallPhase    = 'Standard'
            InstallerType   = 'Winget'
            RequiresNetwork = $true
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'farion1231.CC-Switch'
            WingetSource    = 'winget'
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns = @('CC Switch*')
                Commands            = @('cc-switch.exe')
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'AnyInstalled'
                TargetVersion        = ''
                AllowedMajor         = ''
                RejectMajorAtOrAbove = ''
            }
            ManualActions   = @()
            Safety          = @{
                Ready         = $true
                FailureStatus = ''
                FailureReason = ''
            }
        }

        @{
            Key             = 'nomachine'
            Name            = 'NoMachine Free Server (deprecated)'
            Order           = 18
            InstallOrder    = 990
            InstallPhase    = 'Standard'
            InstallerType   = 'ManualOrSeed'
            RequiresNetwork = $false
            ProxyPolicy     = 'DirectThenAutoProxy'
            WingetId        = 'NoMachine.NoMachine'
            WingetSource    = ''
            WingetVersion   = ''
            StoreProductId  = ''
            Detection       = @{
                DisplayNamePatterns         = @('NoMachine*')
                ExcludedDisplayNamePatterns = @('NoMachine Enterprise Client*')
                Commands            = @()
                AppxNames           = @()
                Services            = @()
                WslDistribution     = ''
            }
            WindowsFeatures = @()
            VersionPolicy   = @{
                Mode                 = 'ProtectedMajor'
                TargetVersion        = '9.8.2'
                AllowedMajor         = '9'
                RejectMajorAtOrAbove = '10'
            }
            ManualActions   = @(
                'This compatibility key is deprecated and no longer installs the NoMachine server. Use nomachine-client for the free outbound-only Enterprise Client.'
            )
            Seed            = @{
                FileName     = ''
                Sha256       = ''
                SignerSubject = ''
                SilentArgs   = @()
            }
            Lifecycle       = @{
                State          = 'Deprecated'
                ReplacementKey = 'nomachine-client'
            }
            Safety          = @{
                Ready         = $false
                FailureStatus = 'ManualActionRequired'
                FailureReason = 'The former NoMachine Free Server entry is deprecated because version 10 no longer provides a free server product.'
            }
        }
    )
}
