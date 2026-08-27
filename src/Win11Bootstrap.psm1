#requires -Version 5.1

Set-StrictMode -Version 2.0

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:CatalogPath = Join-Path $script:RepositoryRoot 'catalog\apps.psd1'
$script:LogPath = $null
$script:DryRun = $false
$script:ProxyTestUri = 'https://www.microsoft.com/favicon.ico'
$script:UiStrings = $null
$script:WinGetClientVersion = '1.29.280'
$script:TrustedWinGetSources = @{
    winget = @{
        Name = 'winget'
        Arg = 'https://cdn.winget.microsoft.com/cache'
        Data = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
        Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
        Type = 'Microsoft.PreIndexed.Package'
        Explicit = $false
        TrustLevel = @('Trusted', 'StoreOrigin')
    }
    msstore = @{
        Name = 'msstore'
        Arg = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
        Data = ''
        Identifier = 'StoreEdgeFD'
        Type = 'Microsoft.Rest'
        Explicit = $false
        TrustLevel = @('Trusted')
    }
}
$script:TrustedMicrosoftSignerSubjects = @(
    'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US',
    'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
)
$script:SupportedStatuses = @(
    'Planned',
    'AlreadyInstalled',
    'Installed',
    'Skipped',
    'NeedsProxy',
    'NeedsRestart',
    'ManualActionRequired',
    'NonCompliant',
    'Failed'
)

function Initialize-UiStrings {
    [CmdletBinding()]
    param()

    $script:UiStrings = $null
    $path = Join-Path $script:RepositoryRoot 'resources\strings.zh-CN.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if ($null -ne $parsed -and -not ($parsed -is [System.Array])) {
            $script:UiStrings = $parsed
        }
    }
    catch {
        # UI localization is optional. Malformed resources never alter the
        # installer behavior and safely fall back to embedded English strings.
        $script:UiStrings = $null
    }
}

function Get-UiText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    if ($null -ne $script:UiStrings) {
        $value = Get-ObjectValue -InputObject $script:UiStrings -Name $Key -Default $null
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $Fallback
}

function Get-AppDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application
    )

    $fallback = [string](Get-ObjectValue -InputObject $Application -Name 'Name' -Default (Get-ObjectValue -InputObject $Application -Name 'Key' -Default 'Unknown'))
    if ($null -ne $script:UiStrings) {
        $names = Get-ObjectValue -InputObject $script:UiStrings -Name 'AppNames' -Default $null
        if ($null -ne $names) {
            $localized = Get-ObjectValue -InputObject $names -Name ([string](Get-ObjectValue -InputObject $Application -Name 'Key')) -Default $null
            if ($localized -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$localized)) {
                return [string]$localized
            }
        }
    }
    return $fallback
}

function Get-StatusDisplayText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $fallbacks = @{
        Planned = 'Planned'
        AlreadyInstalled = 'Already installed; skipped'
        Installed = 'Installed'
        Skipped = 'Skipped'
        NeedsProxy = 'Proxy configuration required'
        NeedsRestart = 'Restart required'
        ManualActionRequired = 'Manual action required'
        NonCompliant = 'Policy conflict detected'
        Failed = 'Failed'
    }
    $fallback = $Status
    if ($fallbacks.ContainsKey($Status)) {
        $fallback = $fallbacks[$Status]
    }
    return Get-UiText -Key $Status -Fallback $fallback
}

function Get-ObjectValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $Default
}

function ConvertTo-StringArray {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        $text = ([string]$item).Trim()
        if ($text.Length -gt 0) {
            [void]$result.Add($text)
        }
    }
    return @($result.ToArray())
}

function Protect-LogText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $safe = $Text
    $safe = [regex]::Replace($safe, '(?i)(https?://)([^\s/:@]+):([^\s/@]+)@', '$1***:***@')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|key|secret|password|passwd|auth|subscription)=)[^&\s]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(?:bearer\s+)[A-Za-z0-9._~+\-/=]+', 'Bearer ***')
    return $safe
}

function Write-BootstrapLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Info',

        [Parameter()]
        [switch]$FileOnly
    )

    $safeMessage = Protect-LogText -Text $Message
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level.ToUpperInvariant(), $safeMessage

    $color = 'Gray'
    switch ($Level) {
        'Success' { $color = 'Green' }
        'Warning' { $color = 'Yellow' }
        'Error' { $color = 'Red' }
        'Debug' { $color = 'DarkGray' }
    }
    if (-not $FileOnly) {
        Write-Host $safeMessage -ForegroundColor $color
    }

    if (-not $script:DryRun -and $script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # A logging failure must not conceal the actual bootstrap result.
            Write-Host ('Unable to append to the log: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Initialize-BootstrapLog {
    [CmdletBinding()]
    param([switch]$DryRun)

    $script:DryRun = [bool]$DryRun
    $script:LogPath = $null
    if ($script:DryRun) {
        return
    }

    if (Test-IsAdministrator) {
        # Elevated code must not follow a user-controlled LOCALAPPDATA link.
        # The helper creates (or revalidates) an ACL-protected, non-reparse
        # ProgramData directory owned by Administrators/System.
        $logDirectory = New-SecureBootstrapSubdirectory -Name 'Logs'
    }
    else {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw 'LOCALAPPDATA could not be resolved; refusing to place logs in an unknown location.'
        }

        $logDirectory = Join-Path $localAppData 'Win11Bootstrap\Logs'
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop)
        }
    }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Join-Path $logDirectory ('bootstrap-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N'))
        $stream = $null
        try {
            # CreateNew is atomic and never truncates a pre-existing file or
            # hardlink. The random name is generated inside the protected log
            # directory, which unprivileged users cannot modify after ACL lock.
            $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $stream.Dispose()
            $stream = $null
            $item = Assert-RegularBootstrapFile -Path $candidate
            $script:LogPath = $item.FullName
            return
        }
        catch [System.IO.IOException] {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
            continue
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
    throw [System.Security.SecurityException]::new('A unique secure bootstrap log could not be created.')
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TrustedMicrosoftExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedRoot
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $resolvedPath = [IO.Path]::GetFullPath($item.FullName)
        $resolvedRoot = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $rootPrefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $resolvedPath -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
            return $false
        }
        $actualSubject = ([string]$signature.SignerCertificate.Subject).Trim()
        return @($script:TrustedMicrosoftSignerSubjects | Where-Object {
            [string]::Equals($_, $actualSubject, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-TrustedSystemExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.\\-]+\.exe$')]
        [string]$RelativePath
    )

    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw [System.Security.SecurityException]::new('The Windows system directory could not be resolved safely.')
    }
    $candidate = Join-Path $systemDirectory $RelativePath
    if (-not [IO.File]::Exists($candidate)) {
        throw [System.IO.FileNotFoundException]::new("The required Windows system executable was not found: '$RelativePath'.", $candidate)
    }
    if (-not (Test-TrustedMicrosoftExecutable -Path $candidate -ExpectedRoot $systemDirectory)) {
        throw [System.Security.SecurityException]::new("The trusted Microsoft executable could not be validated: '$RelativePath'.")
    }
    $resolved = (Get-Item -LiteralPath $candidate -Force -ErrorAction Stop).FullName
    return $resolved
}

function Assert-SupportedEnvironment {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw [System.PlatformNotSupportedException]::new('Windows PowerShell 5.1 or newer is required.')
    }
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw [System.PlatformNotSupportedException]::new('A 64-bit Windows installation and 64-bit PowerShell process are required.')
    }

    $build = 0
    try {
        $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
    }
    catch {
        $build = [Environment]::OSVersion.Version.Build
    }
    if ($build -lt 22000) {
        throw [System.PlatformNotSupportedException]::new('Windows 11 (build 22000 or later) is required.')
    }
}

function Import-AppCatalog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = $script:CatalogPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Application catalog was not found: $Path")
    }

    $catalog = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $schemaVersion = [string](Get-ObjectValue -InputObject $catalog -Name 'SchemaVersion' -Default '')
    if ($schemaVersion -notmatch '^1\.') {
        throw [System.InvalidDataException]::new("Unsupported application catalog schema: '$schemaVersion'.")
    }

    $applications = @(Get-ObjectValue -InputObject $catalog -Name 'Applications' -Default @())
    if ($applications.Count -eq 0) {
        throw [System.InvalidDataException]::new('The application catalog contains no applications.')
    }

    $seenKeys = @{}
    $seenOrders = @{}
    foreach ($app in $applications) {
        $key = [string](Get-ObjectValue -InputObject $app -Name 'Key' -Default '')
        $name = [string](Get-ObjectValue -InputObject $app -Name 'Name' -Default '')
        $order = Get-ObjectValue -InputObject $app -Name 'Order' -Default $null
        $installerType = [string](Get-ObjectValue -InputObject $app -Name 'InstallerType' -Default '')
        if ([string]::IsNullOrWhiteSpace($key) -or $key -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw [System.InvalidDataException]::new("Catalog application key is invalid: '$key'.")
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw [System.InvalidDataException]::new("Catalog application '$key' has no name.")
        }
        if ($null -eq $order -or [int]$order -lt 1) {
            throw [System.InvalidDataException]::new("Catalog application '$key' has an invalid order.")
        }
        if ($installerType -notin @('Winget', 'Store', 'ManualOrSeed', 'Wsl', 'Direct')) {
            throw [System.InvalidDataException]::new("Catalog application '$key' has unsupported InstallerType '$installerType'.")
        }
        if ($seenKeys.ContainsKey($key.ToLowerInvariant())) {
            throw [System.InvalidDataException]::new("Duplicate catalog key: '$key'.")
        }
        if ($seenOrders.ContainsKey([int]$order)) {
            throw [System.InvalidDataException]::new("Duplicate catalog order: '$order'.")
        }
        $seenKeys[$key.ToLowerInvariant()] = $true
        $seenOrders[[int]$order] = $true
    }

    return $catalog
}

function Get-CanonicalKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Applications,

        [Parameter()]
        [AllowNull()]
        [object]$Values,

        [Parameter(Mandatory = $true)]
        [string]$SourceName
    )

    $lookup = @{}
    foreach ($app in $Applications) {
        $key = [string](Get-ObjectValue -InputObject $app -Name 'Key')
        $lookup[$key.ToLowerInvariant()] = $key
    }

    $canonical = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($value in @($Values)) {
        foreach ($part in ([string]$value -split ',')) {
            $candidate = $part.Trim()
            if ($candidate.Length -eq 0) {
                continue
            }
            $normalized = $candidate.ToLowerInvariant()
            if (-not $lookup.ContainsKey($normalized)) {
                throw [System.ArgumentException]::new("Unknown application key '$candidate' in $SourceName.")
            }
            if (-not $seen.ContainsKey($normalized)) {
                [void]$canonical.Add($lookup[$normalized])
                $seen[$normalized] = $true
            }
        }
    }
    return @($canonical.ToArray())
}

function Read-BootstrapConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.ArgumentException]::new("Config file does not exist: '$Path'.")
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 -ErrorAction Stop
        $config = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        throw [System.ArgumentException]::new("Config is not valid JSON: $($_.Exception.Message)")
    }
    if ($null -eq $config -or $config -is [System.Array] -or $config -is [string]) {
        throw [System.ArgumentException]::new('Config root must be a JSON object.')
    }

    $allowed = @('only', 'skip', 'proxyUri', 'seedDirectory', 'noGitHubMirrors')
    foreach ($property in $config.PSObject.Properties) {
        if ($allowed -cnotcontains $property.Name) {
            throw [System.ArgumentException]::new("Unknown config property '$($property.Name)'.")
        }
    }

    $result = @{
        Path = $resolvedPath
    }
    foreach ($arrayName in @('only', 'skip')) {
        $property = $config.PSObject.Properties[$arrayName]
        if ($null -ne $property) {
            if ($null -eq $property.Value -or -not ($property.Value -is [System.Array])) {
                throw [System.ArgumentException]::new("Config property '$arrayName' must be an array of application keys.")
            }
            foreach ($item in $property.Value) {
                if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace([string]$item)) {
                    throw [System.ArgumentException]::new("Config property '$arrayName' must contain only non-empty strings.")
                }
            }
            $result[$arrayName] = @($property.Value)
        }
    }

    foreach ($stringName in @('proxyUri', 'seedDirectory')) {
        $property = $config.PSObject.Properties[$stringName]
        if ($null -ne $property) {
            if (-not ($property.Value -is [string]) -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw [System.ArgumentException]::new("Config property '$stringName' must be a non-empty string.")
            }
            $result[$stringName] = [string]$property.Value
        }
    }

    $mirrorProperty = $config.PSObject.Properties['noGitHubMirrors']
    if ($null -ne $mirrorProperty) {
        if (-not ($mirrorProperty.Value -is [bool])) {
            throw [System.ArgumentException]::new("Config property 'noGitHubMirrors' must be a boolean.")
        }
        $result['noGitHubMirrors'] = [bool]$mirrorProperty.Value
    }
    return $result
}

function Resolve-ProxyUriValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $uri = $null
    if (-not [Uri]::TryCreate(([string]$Value).Trim(), [UriKind]::Absolute, [ref]$uri)) {
        throw [System.ArgumentException]::new('ProxyUri must be an absolute HTTP or HTTPS URI.')
    }
    if ($uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw [System.ArgumentException]::new('ProxyUri must use the http or https scheme and include a host.')
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($uri.Query) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw [System.ArgumentException]::new('ProxyUri must not contain credentials, a query, or a fragment. Use a credential-free process-scoped proxy endpoint.')
    }
    return $uri.AbsoluteUri
}

function Resolve-BootstrapOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Invocation,

        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    $applications = @(Get-ObjectValue -InputObject $Catalog -Name 'Applications')
    $config = @{}
    if ($Invocation.Contains('Config')) {
        $config = Read-BootstrapConfig -Path ([string]$Invocation['Config'])
    }

    $onlySource = @()
    if ($Invocation.Contains('Only')) {
        $onlySource = @($Invocation['Only'])
    }
    elseif ($config.ContainsKey('only')) {
        $onlySource = @($config['only'])
    }

    $skipSource = @()
    if ($config.ContainsKey('skip')) {
        $skipSource += @($config['skip'])
    }
    if ($Invocation.Contains('Skip')) {
        $skipSource += @($Invocation['Skip'])
    }

    $onlyKeys = @(Get-CanonicalKeys -Applications $applications -Values $onlySource -SourceName 'only')
    $skipKeys = @(Get-CanonicalKeys -Applications $applications -Values $skipSource -SourceName 'skip')

    if (($Invocation.Contains('Only') -or $config.ContainsKey('only')) -and $onlyKeys.Count -eq 0) {
        throw [System.ArgumentException]::new('The only selection must contain at least one application key.')
    }

    $proxyValue = $null
    if ($Invocation.Contains('ProxyUri')) {
        $proxyValue = $Invocation['ProxyUri']
    }
    elseif ($config.ContainsKey('proxyUri')) {
        $proxyValue = $config['proxyUri']
    }
    $proxyUri = Resolve-ProxyUriValue -Value $proxyValue

    $seedValue = $null
    if ($Invocation.Contains('SeedDirectory')) {
        $seedValue = [string]$Invocation['SeedDirectory']
    }
    elseif ($config.ContainsKey('seedDirectory')) {
        $seedValue = [string]$config['seedDirectory']
    }
    $seedDirectory = $null
    if (-not [string]::IsNullOrWhiteSpace($seedValue)) {
        if (-not (Test-Path -LiteralPath $seedValue -PathType Container)) {
            throw [System.ArgumentException]::new("SeedDirectory does not exist or is not a directory: '$seedValue'.")
        }
        $seedDirectory = (Resolve-Path -LiteralPath $seedValue -ErrorAction Stop).ProviderPath
    }

    $noMirrors = $false
    if ($config.ContainsKey('noGitHubMirrors')) {
        $noMirrors = [bool]$config['noGitHubMirrors']
    }
    if ($Invocation.Contains('NoGitHubMirrors')) {
        $noMirrors = [bool]$Invocation['NoGitHubMirrors']
    }

    $showMenu = -not $Invocation.Contains('Only') -and
        -not $Invocation.Contains('Skip') -and
        -not $Invocation.Contains('Config') -and
        -not $Invocation.Contains('Yes')

    return [pscustomobject]@{
        ConfigPath        = $(if ($config.ContainsKey('Path')) { $config['Path'] } else { $null })
        OnlyKeys         = @($onlyKeys)
        SkipKeys         = @($skipKeys)
        ProxyUri         = $proxyUri
        SeedDirectory    = $seedDirectory
        NoGitHubMirrors  = $noMirrors
        Yes              = $(if ($Invocation.Contains('Yes')) { [bool]$Invocation['Yes'] } else { $false })
        ShowMenu         = $showMenu
        HasOnlySelection = ($Invocation.Contains('Only') -or $config.ContainsKey('only'))
    }
}

function Assert-RegularBootstrapDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = New-Object IO.DirectoryInfo($Path)
    if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [System.Security.SecurityException]::new("Bootstrap path is not a regular directory: '$Path'.")
    }
    return $item.FullName
}

function Assert-RegularBootstrapFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = New-Object IO.FileInfo($Path)
    if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [System.Security.SecurityException]::new("Bootstrap path is not a regular file: '$Path'.")
    }
    return $item
}

function Get-Sha256FileHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-BootstrapRuntimeSnapshotManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).ProviderPath
    $sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedScript)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $relativePaths = @(
        'bootstrap.ps1',
        'src\Win11Bootstrap.psm1',
        'catalog\apps.psd1',
        'resources\strings.zh-CN.json'
    )

    $directories = @($sourceRoot)
    foreach ($relativeDirectory in @('src', 'catalog', 'resources')) {
        $directories += [IO.Path]::GetFullPath((Join-Path $sourceRoot $relativeDirectory))
    }
    foreach ($directory in $directories) {
        [void](Assert-RegularBootstrapDirectory -Path $directory)
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $relativePaths) {
        $path = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relativePath))
        $requiredPrefix = $sourceRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw [System.Security.SecurityException]::new('A runtime snapshot path escaped the repository root.')
        }
        $item = Assert-RegularBootstrapFile -Path $path
        $hash = Get-Sha256FileHex -Path $path
        [void]$files.Add([pscustomobject]@{
            RelativePath = $relativePath
            Sha256 = $hash
            Length = [long]$item.Length
        })
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        SourceRoot = $sourceRoot
        Files = @($files.ToArray())
    }
}

function Assert-BootstrapRuntimeSnapshotManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    if ([int](Get-ObjectValue -InputObject $Manifest -Name 'SchemaVersion' -Default 0) -ne 1) {
        throw [System.Security.SecurityException]::new('The runtime snapshot manifest schema is invalid.')
    }
    $sourceRoot = [string](Get-ObjectValue -InputObject $Manifest -Name 'SourceRoot' -Default '')
    $expected = @(
        'bootstrap.ps1',
        'src\Win11Bootstrap.psm1',
        'catalog\apps.psd1',
        'resources\strings.zh-CN.json'
    )
    $files = @(Get-ObjectValue -InputObject $Manifest -Name 'Files' -Default @())
    if ([string]::IsNullOrWhiteSpace($sourceRoot) -or $files.Count -ne $expected.Count) {
        throw [System.Security.SecurityException]::new('The runtime snapshot manifest is incomplete.')
    }

    $seen = @{}
    foreach ($entry in $files) {
        $relativePath = [string](Get-ObjectValue -InputObject $entry -Name 'RelativePath' -Default '')
        $expectedHash = [string](Get-ObjectValue -InputObject $entry -Name 'Sha256' -Default '')
        $expectedLengthText = [string](Get-ObjectValue -InputObject $entry -Name 'Length' -Default '')
        if ($relativePath -notin $expected -or $seen.ContainsKey($relativePath) -or
            $expectedHash -notmatch '^[A-Fa-f0-9]{64}$' -or $expectedLengthText -notmatch '^(0|[1-9][0-9]*)$') {
            throw [System.Security.SecurityException]::new('The runtime snapshot manifest contains an unexpected entry.')
        }
        $expectedLength = [long]$expectedLengthText
        $seen[$relativePath] = $true
        $path = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relativePath))
        $item = Assert-RegularBootstrapFile -Path $path
        if ([long]$item.Length -ne $expectedLength) {
            throw [System.Security.SecurityException]::new("Runtime snapshot source length changed before elevation: '$relativePath'.")
        }
        $actualHash = Get-Sha256FileHex -Path $path
        if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw [System.Security.SecurityException]::new("Runtime snapshot source changed before elevation: '$relativePath'.")
        }
    }
    foreach ($relativePath in $expected) {
        if (-not $seen.ContainsKey($relativePath)) {
            throw [System.Security.SecurityException]::new("Runtime snapshot manifest is missing '$relativePath'.")
        }
    }
}

function Get-BootstrapElevationLoaderScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-f0-9]{32}$')]
        [string]$PayloadId
    )

    $loaderManifest = [ordered]@{
        SchemaVersion = 1
        PayloadId = $PayloadId
        SourceRoot = [string]$Manifest.SourceRoot
        Files = @($Manifest.Files)
    }
    $manifestJson = ConvertTo-Json -InputObject $loaderManifest -Compress -Depth 5
    $manifestBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifestJson))

    $template = @'
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function New-LockedAcl {
    $admins = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $system = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in @($admins, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

function Assert-LockedDirectory([string]$Path, [Security.AccessControl.DirectorySecurity]$Acl) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [Security.SecurityException]::new("Secure runtime path is not a regular directory: '$Path'.")
    }
    $actual = $item.GetAccessControl([Security.AccessControl.AccessControlSections]'Access, Owner')
    if (-not $actual.AreAccessRulesProtected) {
        throw [Security.SecurityException]::new("Secure runtime ACL inherits permissions: '$Path'.")
    }
    $expectedOwner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $actualOwner = $actual.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($actualOwner -ne $expectedOwner) {
        throw [Security.SecurityException]::new("Secure runtime owner is unexpected: '$Path'.")
    }
    $required = @{
        (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value = $false
        (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value = $false
    }
    $rules = @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $required.Count) {
        throw [Security.SecurityException]::new("Secure runtime ACL rule count is unexpected: '$Path'.")
    }
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if (-not $required.ContainsKey($sid) -or $required[$sid] -or $rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw [Security.SecurityException]::new("Secure runtime ACL is not the exact reviewed policy: '$Path'.")
        }
        $required[$sid] = $true
    }
    if (@($required.Values | Where-Object { -not $_ }).Count -ne 0) {
        throw [Security.SecurityException]::new("Secure runtime ACL is missing a required principal: '$Path'.")
    }
    return $item.FullName
}

function Ensure-LockedDirectory([string]$Path, [Security.AccessControl.DirectorySecurity]$Acl) {
    if (-not [IO.Directory]::Exists($Path)) {
        [void][IO.Directory]::CreateDirectory($Path, $Acl)
    }
    return Assert-LockedDirectory -Path $Path -Acl $Acl
}

function Remove-LockedSnapshot([string]$Path, [string]$RuntimeRoot) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $target = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($target), $root, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^[a-f0-9]{32}$') {
        throw [Security.SecurityException]::new('Refusing to clean a path outside the secure runtime root.')
    }
    $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [Security.SecurityException]::new('Refusing to clean a runtime reparse point.')
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [Security.SecurityException]::new('Refusing to recursively clean a runtime tree containing a reparse point.')
        }
    }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
}

$manifestText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MANIFEST_BASE64__'))
$manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
$exitCode = 20
$stage = $null
$runtimeRoot = $null
$environmentName = $null
try {
    if ([int]$manifest.SchemaVersion -ne 1 -or [string]$manifest.PayloadId -notmatch '^[a-f0-9]{32}$') {
        throw [Security.SecurityException]::new('The secure runtime manifest header is invalid.')
    }
    $environmentName = 'WIN11_BOOTSTRAP_ELEVATION_{0}' -f ([string]$manifest.PayloadId).ToUpperInvariant()
    $optionPayload = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
    if ([string]::IsNullOrWhiteSpace($optionPayload) -or $optionPayload.Length -gt 24576) {
        throw [Security.SecurityException]::new('The elevation option payload is missing or oversized.')
    }
    $optionBytes = [Convert]::FromBase64String($optionPayload)
    if ($optionBytes.Length -gt 16384) {
        throw [Security.SecurityException]::new('The elevation option payload is oversized.')
    }
    $optionObject = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($optionBytes)) -ErrorAction Stop
    if ($null -eq $optionObject -or $optionObject -is [Array]) {
        throw [Security.SecurityException]::new('The elevation option payload is invalid.')
    }
    foreach ($property in $optionObject.PSObject.Properties) {
        if ($property.Name -notin @('Only', 'Skip', 'Yes', 'ProxyUri', 'SeedDirectory', 'NoGitHubMirrors')) {
            throw [Security.SecurityException]::new('The elevation option payload contains an unexpected property.')
        }
    }

    $sourceRoot = [IO.Path]::GetFullPath([string]$manifest.SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $sourceRootItem = Get-Item -LiteralPath $sourceRoot -Force -ErrorAction Stop
    if (-not $sourceRootItem.PSIsContainer -or (($sourceRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [Security.SecurityException]::new('The runtime snapshot source root is not a regular directory.')
    }
    $expected = @{
        'bootstrap.ps1' = $false
        'src\Win11Bootstrap.psm1' = $false
        'catalog\apps.psd1' = $false
        'resources\strings.zh-CN.json' = $false
    }
    $entries = @($manifest.Files)
    if ($entries.Count -ne $expected.Count) {
        throw [Security.SecurityException]::new('The secure runtime manifest is incomplete.')
    }
    foreach ($entry in $entries) {
        $relativePath = [string]$entry.RelativePath
        if (-not $expected.ContainsKey($relativePath) -or $expected[$relativePath] -or
            [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [string]$entry.Length -notmatch '^(0|[1-9][0-9]*)$') {
            throw [Security.SecurityException]::new('The secure runtime manifest contains an unexpected entry.')
        }
        $expected[$relativePath] = $true
    }

    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw [Security.SecurityException]::new('ProgramData could not be resolved for the secure runtime snapshot.')
    }
    $programDataItem = Get-Item -LiteralPath $programData -Force -ErrorAction Stop
    if (-not $programDataItem.PSIsContainer -or (($programDataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [Security.SecurityException]::new('ProgramData is not a regular directory.')
    }
    $acl = New-LockedAcl
    $productRoot = Ensure-LockedDirectory -Path (Join-Path $programData 'Win11Bootstrap') -Acl $acl
    $runtimeRoot = Ensure-LockedDirectory -Path (Join-Path $productRoot 'Runtime') -Acl $acl
    for ($attempt = 0; $attempt -lt 10 -and $null -eq $stage; $attempt++) {
        $candidate = Join-Path $runtimeRoot ([Guid]::NewGuid().ToString('N'))
        if ([IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate)) { continue }
        try {
            [void][IO.Directory]::CreateDirectory($candidate, $acl)
            $stage = Assert-LockedDirectory -Path $candidate -Acl $acl
        }
        catch [IO.IOException] { continue }
    }
    if ($null -eq $stage) {
        throw [Security.SecurityException]::new('A unique secure runtime snapshot could not be created.')
    }

    foreach ($directoryName in @('src', 'catalog', 'resources')) {
        [void](Ensure-LockedDirectory -Path (Join-Path $stage $directoryName) -Acl $acl)
    }
    foreach ($entry in $entries) {
        $relativePath = [string]$entry.RelativePath
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relativePath))
        $destination = [IO.Path]::GetFullPath((Join-Path $stage $relativePath))
        if (-not $source.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            -not $destination.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw [Security.SecurityException]::new('A secure runtime path escaped its root.')
        }
        $sourceParent = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($source)) -Force -ErrorAction Stop
        $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if (-not $sourceParent.PSIsContainer -or (($sourceParent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $sourceItem.PSIsContainer -or (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [long]$sourceItem.Length -ne [long]$entry.Length) {
            throw [Security.SecurityException]::new("Runtime snapshot source became unsafe: '$relativePath'.")
        }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($sourceHash, [string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw [Security.SecurityException]::new("Runtime snapshot source changed before copy: '$relativePath'.")
        }
        [IO.File]::Copy($source, $destination, $false)
        $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($destinationItem.PSIsContainer -or (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [long]$destinationItem.Length -ne [long]$entry.Length -or
            -not [string]::Equals($destinationHash, [string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw [Security.SecurityException]::new("Secure runtime copy verification failed: '$relativePath'.")
        }
    }

    $secureBootstrap = Join-Path $stage 'bootstrap.ps1'
    if ($secureBootstrap.Contains('"')) {
        throw [Security.SecurityException]::new('The secure runtime path contains an invalid character.')
    }
    $powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo = New-Object Diagnostics.ProcessStartInfo
    $processInfo.FileName = $powerShellPath
    $processInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $secureBootstrap + '" -ElevatedPayloadId ' + [string]$manifest.PayloadId
    $processInfo.WorkingDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    $processInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($processInfo)
    if ($null -eq $process) {
        throw [InvalidOperationException]::new('The secure runtime process could not be started.')
    }
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
}
catch [Security.SecurityException] {
    [Console]::Error.WriteLine('Secure elevation bootstrap rejected unsafe runtime state: {0}' -f $_.Exception.Message)
    $exitCode = 30
}
catch {
    [Console]::Error.WriteLine('Secure elevation bootstrap failed: {0}' -f $_.Exception.Message)
    $exitCode = 20
}
finally {
    if ($environmentName) {
        [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
    }
    if ($stage -and $runtimeRoot) {
        try { Remove-LockedSnapshot -Path $stage -RuntimeRoot $runtimeRoot }
        catch [Security.SecurityException] {
            [Console]::Error.WriteLine('Secure runtime cleanup rejected unsafe state: {0}' -f $_.Exception.Message)
            $exitCode = 30
        }
        catch {
            [Console]::Error.WriteLine('Secure runtime cleanup failed: {0}' -f $_.Exception.Message)
            $exitCode = 20
        }
    }
}
exit $exitCode
'@
    return $template.Replace('__MANIFEST_BASE64__', $manifestBase64)
}

function Get-BootstrapElevationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-f0-9]{32}$')]
        [string]$Id
    )

    $name = 'WIN11_BOOTSTRAP_ELEVATION_{0}' -f $Id.ToUpperInvariant()
    $payload = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    if ([string]::IsNullOrWhiteSpace($payload)) {
        throw [System.Security.SecurityException]::new('The elevation payload is missing or has already been consumed.')
    }

    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $object = ConvertFrom-Json -InputObject $decoded -ErrorAction Stop
    }
    catch {
        throw [System.Security.SecurityException]::new('The elevation payload is invalid.')
    }

    $result = @{}
    foreach ($property in $object.PSObject.Properties) {
        if ($property.Name -notin @('Only', 'Skip', 'Yes', 'ProxyUri', 'SeedDirectory', 'NoGitHubMirrors')) {
            throw [System.Security.SecurityException]::new("Unexpected elevation payload property '$($property.Name)'.")
        }

        switch ($property.Name) {
            { $_ -in @('Yes', 'NoGitHubMirrors') } {
                if ($property.Value -isnot [bool]) {
                    throw [System.Security.SecurityException]::new("Elevation payload property '$($property.Name)' must be a Boolean.")
                }
                $result[$property.Name] = [bool]$property.Value
                break
            }
            { $_ -in @('Only', 'Skip') } {
                if ($null -eq $property.Value -or $property.Value -is [string]) {
                    throw [System.Security.SecurityException]::new("Elevation payload property '$($property.Name)' must be a string array.")
                }
                $values = @($property.Value)
                foreach ($value in $values) {
                    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                        throw [System.Security.SecurityException]::new("Elevation payload property '$($property.Name)' contains an invalid value.")
                    }
                }
                $result[$property.Name] = [string[]]$values
                break
            }
            default {
                if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
                    throw [System.Security.SecurityException]::new("Elevation payload property '$($property.Name)' must be a non-empty string.")
                }
                $result[$property.Name] = [string]$property.Value
            }
        }
    }
    return $result
}

function ConvertTo-BootstrapEncodedLoaderArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LoaderScript
    )

    $inputBytes = [Text.Encoding]::UTF8.GetBytes($LoaderScript)
    $memory = New-Object IO.MemoryStream
    try {
        $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Compress, $true)
        try {
            $gzip.Write($inputBytes, 0, $inputBytes.Length)
        }
        finally {
            $gzip.Dispose()
        }
        $compressed = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
    }
    $compressedBase64 = [Convert]::ToBase64String($compressed)
    $wrapper = '$b=[Convert]::FromBase64String(''' + $compressedBase64 + ''');$m=New-Object IO.MemoryStream(,$b);$z=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);$r=New-Object IO.StreamReader($z,[Text.Encoding]::UTF8);$t=$r.ReadToEnd();$r.Dispose();$z.Dispose();$m.Dispose();&([Management.Automation.ScriptBlock]::Create($t))'
    $encodedWrapper = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    return '-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand {0}' -f $encodedWrapper
}

function Start-BootstrapElevated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Invocation
    )

    if ($Invocation.Contains('Config')) {
        throw [System.Security.SecurityException]::new('Config files must be resolved to canonical options before elevation.')
    }

    $payloadObject = @{}
    foreach ($name in @('Only', 'Skip', 'Yes', 'ProxyUri', 'SeedDirectory', 'NoGitHubMirrors')) {
        if ($Invocation.Contains($name)) {
            if ($name -in @('Yes', 'NoGitHubMirrors')) {
                # SwitchParameter serializes as an object with IsPresent. The
                # elevated entry point expects a Boolean that can bind to a
                # switch, so normalize it before crossing the process boundary.
                $payloadObject[$name] = [bool]$Invocation[$name]
            }
            elseif ($name -in @('Only', 'Skip')) {
                $values = [string[]]@($Invocation[$name])
                if ($values.Count -gt 100) {
                    throw [System.Security.SecurityException]::new("Elevation payload property '$name' contains too many values.")
                }
                foreach ($value in $values) {
                    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 128) {
                        throw [System.Security.SecurityException]::new("Elevation payload property '$name' contains an invalid value.")
                    }
                }
                $payloadObject[$name] = $values
            }
            else {
                $value = [string]$Invocation[$name]
                if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 8192) {
                    throw [System.Security.SecurityException]::new("Elevation payload property '$name' is invalid or oversized.")
                }
                if ($name -eq 'ProxyUri') {
                    $value = Resolve-ProxyUriValue -Value $value
                }
                $payloadObject[$name] = $value
            }
        }
    }

    $manifest = Get-BootstrapRuntimeSnapshotManifest -ScriptPath $ScriptPath
    Assert-BootstrapRuntimeSnapshotManifest -Manifest $manifest
    $id = [Guid]::NewGuid().ToString('N')
    $environmentName = 'WIN11_BOOTSTRAP_ELEVATION_{0}' -f $id.ToUpperInvariant()
    $json = ConvertTo-Json -InputObject $payloadObject -Compress -Depth 5
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($json)
    if ($payloadBytes.Length -gt 16384) {
        throw [System.Security.SecurityException]::new('The elevation option payload is too large.')
    }
    $payload = [Convert]::ToBase64String($payloadBytes)
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($environmentName, 'Process'))) {
        throw [System.Security.SecurityException]::new('The random elevation payload slot was unexpectedly occupied.')
    }
    [Environment]::SetEnvironmentVariable($environmentName, $payload, 'Process')

    try {
        # Recheck immediately before process creation. The elevated loader also
        # verifies every copied byte against this pre-UAC manifest, so changes
        # made while the consent UI is open fail closed before repository code
        # can execute with administrator rights.
        Assert-BootstrapRuntimeSnapshotManifest -Manifest $manifest
        $loaderScript = Get-BootstrapElevationLoaderScript -Manifest $manifest -PayloadId $id
        $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $loaderScript
        $powerShellPath = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
        if (($powerShellPath.Length + 1 + $arguments.Length) -gt 28000) {
            throw [System.Security.SecurityException]::new('The secure elevation command exceeds the conservative Windows command-line budget.')
        }
        $trustedWorkingDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if ([string]::IsNullOrWhiteSpace($trustedWorkingDirectory)) {
            throw [System.Security.SecurityException]::new('The trusted Windows system directory could not be resolved for elevation.')
        }
        $process = Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList $arguments -WorkingDirectory $trustedWorkingDirectory -Wait -PassThru -ErrorAction Stop
        return [int]$process.ExitCode
    }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-Host 'Administrator elevation was cancelled. No changes were made.' -ForegroundColor Yellow
            return 20
        }
        throw
    }
    finally {
        [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
    }
}

function ConvertFrom-SelectionExpression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Expression,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 10000)]
        [int]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($Expression)) {
        return @(1..$Maximum)
    }
    if ($Expression.Trim() -ieq 'all') {
        return @(1..$Maximum)
    }
    if ($Expression.Trim() -ieq 'none') {
        return @()
    }

    $indexes = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    foreach ($tokenValue in ($Expression -split ',')) {
        $token = $tokenValue.Trim()
        if ($token -match '^(\d+)$') {
            $start = [int]$Matches[1]
            $finish = $start
        }
        elseif ($token -match '^(\d+)\s*-\s*(\d+)$') {
            $start = [int]$Matches[1]
            $finish = [int]$Matches[2]
        }
        else {
            throw [System.ArgumentException]::new("Invalid menu selection '$token'. Use numbers, commas, and ranges such as 1,3-5.")
        }
        if ($start -lt 1 -or $finish -gt $Maximum -or $finish -lt $start) {
            throw [System.ArgumentException]::new("Menu selection '$token' is outside the range 1-$Maximum.")
        }
        foreach ($index in $start..$finish) {
            if (-not $seen.ContainsKey($index)) {
                [void]$indexes.Add($index)
                $seen[$index] = $true
            }
        }
    }
    if ($indexes.Count -eq 0) {
        throw [System.ArgumentException]::new('At least one application must be selected.')
    }
    return @($indexes.ToArray())
}

function Test-InteractiveConsole {
    [CmdletBinding()]
    param()

    try {
        return -not [Console]::IsInputRedirected
    }
    catch {
        return $Host.Name -eq 'ConsoleHost'
    }
}

function Select-ApplicationsInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Applications
    )

    if (-not (Test-InteractiveConsole)) {
        throw [System.ArgumentException]::new('Interactive selection is unavailable. Use -Only/-Skip or -Config and add -Yes for automation.')
    }

    $ordered = @($Applications | Sort-Object { [int](Get-ObjectValue -InputObject $_ -Name 'Order') })
    Write-Host ''
    Write-Host (Get-UiText -Key 'SelectTitle' -Fallback 'Select applications to install (press Enter for all):') -ForegroundColor Cyan
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        Write-Host ('  {0,2}. {1} [{2}]' -f ($index + 1), (Get-AppDisplayName -Application $ordered[$index]), (Get-ObjectValue -InputObject $ordered[$index] -Name 'Key'))
    }
    $expression = Read-Host (Get-UiText -Key 'SelectionPrompt' -Fallback 'Selection (example: 1,3-5; Enter selects all)')
    $indexes = @(ConvertFrom-SelectionExpression -Expression $expression -Maximum $ordered.Count)
    $selected = foreach ($selectionIndex in $indexes) {
        $ordered[$selectionIndex - 1]
    }
    return @($selected)
}

function Get-UninstallEntries {
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($path in $paths) {
        try {
            foreach ($entry in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
                if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectValue -InputObject $entry -Name 'DisplayName' -Default ''))) {
                    [void]$entries.Add($entry)
                }
            }
        }
        catch {
            # An inaccessible registry view is not evidence of absence; other
            # detectors still run, and the error is included only at Debug.
            Write-Debug 'An uninstall registry view could not be read.'
        }
    }
    return @($entries.ToArray())
}

function Get-MajorVersion {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Version
    )

    $text = ([string]$Version).Trim()
    if ($text -match '^(?i:v)?\s*(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Get-ServiceProductVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    try {
        $escapedName = $ServiceName.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $escapedName) -ErrorAction Stop
        if ($null -eq $service -or [string]::IsNullOrWhiteSpace([string]$service.PathName)) {
            return $null
        }
        $pathText = [Environment]::ExpandEnvironmentVariables([string]$service.PathName).Trim()
        $executablePath = $null
        if ($pathText -match '^"([^"]+)"') {
            $executablePath = $Matches[1]
        }
        elseif ($pathText -match '^(.+?\.exe)(?:\s|$)') {
            $executablePath = $Matches[1]
        }
        if ($executablePath -and (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            return (Get-Item -LiteralPath $executablePath -ErrorAction Stop).VersionInfo.ProductVersion
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-WslDistributions {
    [CmdletBinding()]
    param()

    try {
        $wslPath = Get-TrustedSystemExecutablePath -RelativePath 'wsl.exe'
    }
    catch {
        return @()
    }
    try {
        $output = & $wslPath --list --verbose 2>$null
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        # Windows PowerShell may surface wsl.exe's UTF-16 output with embedded
        # NULs. Parse rows from the right so localized headers are ignored and
        # a distribution is only complete when WSL reports VERSION 2.
        $distributions = New-Object System.Collections.Generic.List[object]
        foreach ($line in @($output)) {
            $text = ([string]$line).Replace(([string][char]0), '').Trim()
            if ($text -match '^\*?\s*(?<Name>.+?)\s+(?<State>\S+)\s+(?<Version>\d+)\s*$') {
                [void]$distributions.Add([pscustomobject]@{
                    Name = [string]$Matches['Name']
                    State = [string]$Matches['State']
                    Version = [int]$Matches['Version']
                })
            }
        }
        return @($distributions.ToArray())
    }
    catch {
        return @()
    }
}

function Test-AppInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter()]
        [AllowNull()]
        [object[]]$UninstallEntries,

        [Parameter()]
        [switch]$DryRun
    )

    if ($null -eq $UninstallEntries) {
        $UninstallEntries = @(Get-UninstallEntries)
    }
    $detection = Get-ObjectValue -InputObject $Application -Name 'Detection' -Default @{}
    $policy = Get-ObjectValue -InputObject $Application -Name 'VersionPolicy' -Default @{}
    # Do not name this variable $matches: PowerShell variable names are case
    # insensitive and the -match operator writes to the automatic $Matches.
    $detectedItems = New-Object System.Collections.Generic.List[object]

    foreach ($pattern in (ConvertTo-StringArray (Get-ObjectValue -InputObject $detection -Name 'DisplayNamePatterns' -Default @()))) {
        foreach ($entry in $UninstallEntries) {
            $displayName = [string](Get-ObjectValue -InputObject $entry -Name 'DisplayName' -Default '')
            if ($displayName -like $pattern) {
                [void]$detectedItems.Add([pscustomobject]@{
                    Kind = 'Uninstall'
                    Name = $displayName
                    Version = [string](Get-ObjectValue -InputObject $entry -Name 'DisplayVersion' -Default '')
                })
            }
        }
    }

    foreach ($commandName in (ConvertTo-StringArray (Get-ObjectValue -InputObject $detection -Name 'Commands' -Default @()))) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $version = ''
            try {
                $version = (Get-Item -LiteralPath $command.Source -ErrorAction Stop).VersionInfo.ProductVersion
            }
            catch { Write-Debug 'Command version metadata could not be read.' }
            [void]$detectedItems.Add([pscustomobject]@{ Kind = 'Command'; Name = $commandName; Version = [string]$version })
        }
    }

    foreach ($appxName in (ConvertTo-StringArray (Get-ObjectValue -InputObject $detection -Name 'AppxNames' -Default @()))) {
        try {
            foreach ($package in @(Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue)) {
                [void]$detectedItems.Add([pscustomobject]@{ Kind = 'Appx'; Name = $package.Name; Version = [string]$package.Version })
            }
        }
        catch { Write-Debug 'An AppX detector could not be queried.' }
    }

    foreach ($serviceName in (ConvertTo-StringArray (Get-ObjectValue -InputObject $detection -Name 'Services' -Default @()))) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            [void]$detectedItems.Add([pscustomobject]@{ Kind = 'Service'; Name = $service.Name; Version = [string](Get-ServiceProductVersion -ServiceName $service.Name) })
        }
    }

    # WSL is a Windows system component even before the requested distribution
    # exists. Generic command/ARP/AppX/service evidence (especially wsl.exe)
    # must therefore never satisfy the WSL application contract by itself.
    if ([string](Get-ObjectValue -InputObject $Application -Name 'InstallerType' -Default '') -eq 'Wsl') {
        $detectedItems.Clear()
    }

    $wslDistribution = [string](Get-ObjectValue -InputObject $detection -Name 'WslDistribution' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($wslDistribution)) {
        $distributionFound = @(Get-WslDistributions | Where-Object { $_.Name -ieq $wslDistribution -and $_.Version -eq 2 }).Count -gt 0
        # A registered VERSION 2 distribution cannot exist without the WSL 2
        # platform having been enabled at installation time. It is also the
        # strongest idempotency evidence and remains readable without UAC,
        # whereas Get-WindowsOptionalFeature -Online fails with ERROR_ELEVATION_REQUIRED
        # during a non-elevated -WhatIf run.
        if ($distributionFound) {
            [void]$detectedItems.Add([pscustomobject]@{ Kind = 'Wsl'; Name = $wslDistribution; Version = [string](Get-ObjectValue -InputObject $policy -Name 'TargetVersion' -Default '') })
        }
    }

    # WinGet's local package database is a useful exact detector for Store
    # packages and executables that do not register a stable command/AppX name.
    # This is detection only: ManualOrSeed entries are never installed merely
    # because they retain a WingetId as a hint.
    $wingetId = [string](Get-ObjectValue -InputObject $Application -Name 'WingetId' -Default '')
    if (-not $DryRun -and -not [string]::IsNullOrWhiteSpace($wingetId) -and (Get-WingetCommandPath)) {
        # Keep detection local and side-effect free: do not select/update a
        # source or accept source agreements before the execution plan is
        # confirmed (and especially not during -WhatIf).
        $sourceTrust = Test-TrustedWinGetSources
        if ($sourceTrust.Trusted) {
            $listArguments = @('list', '--id', $wingetId, '--exact', '--disable-interactivity')
            $listResult = Invoke-WingetRaw -Arguments $listArguments
        }
        else {
            $listResult = [pscustomobject]@{ ExitCode = 126; Output = '' }
        }
        if ($listResult.ExitCode -eq 0 -and $listResult.Output -match [regex]::Escape($wingetId)) {
            $listedVersion = ''
            $linePattern = '(?im)^\s*.*?\s+' + [regex]::Escape($wingetId) + '\s+(\S+)'
            if ($listResult.Output -match $linePattern) {
                $listedVersion = [string]$Matches[1]
            }
            [void]$detectedItems.Add([pscustomobject]@{ Kind = 'WinGet'; Name = $wingetId; Version = $listedVersion })
        }
    }

    $rejectMajorText = [string](Get-ObjectValue -InputObject $policy -Name 'RejectMajorAtOrAbove' -Default '')
    if ($rejectMajorText -match '^\d+$') {
        $rejectMajor = [int]$rejectMajorText
        $unknownMajorItem = $null
        foreach ($detectedItem in $detectedItems) {
            $major = Get-MajorVersion -Version $detectedItem.Version
            if ($null -eq $major -and [string]$detectedItem.Name -match '(?i)(?:^|[\s_-])v?(\d+)(?:\.|\s|$)') {
                $major = [int]$Matches[1]
            }
            if ($null -eq $major -and $null -eq $unknownMajorItem) {
                $unknownMajorItem = $detectedItem
            }
            if ($null -ne $major -and $major -ge $rejectMajor) {
                return [pscustomobject]@{
                    Installed = $true
                    NonCompliant = $true
                    Version = [string]$detectedItem.Version
                    Evidence = ('{0}: {1}' -f $detectedItem.Kind, $detectedItem.Name)
                    Detail = ('Detected protected major version {0}; versions {1} and later are forbidden by the catalog.' -f $major, $rejectMajor)
                }
            }
        }
        if ($null -ne $unknownMajorItem) {
            return [pscustomobject]@{
                Installed = $true
                NonCompliant = $true
                Version = [string]$unknownMajorItem.Version
                Evidence = ('{0}: {1}' -f $unknownMajorItem.Kind, $unknownMajorItem.Name)
                Detail = 'A protected product was detected, but its major version could not be verified; automatic skip or replacement is forbidden.'
            }
        }
    }

    if ($detectedItems.Count -gt 0) {
        $first = $detectedItems[0]
        return [pscustomobject]@{
            Installed = $true
            NonCompliant = $false
            Version = [string]$first.Version
            Evidence = ('{0}: {1}' -f $first.Kind, $first.Name)
            Detail = 'An installed instance was detected; upgrades are intentionally skipped.'
        }
    }

    return [pscustomobject]@{
        Installed = $false
        NonCompliant = $false
        Version = ''
        Evidence = ''
        Detail = 'No installed instance was detected.'
    }
}

function New-BootstrapResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Planned', 'AlreadyInstalled', 'Installed', 'Skipped', 'NeedsProxy', 'NeedsRestart', 'ManualActionRequired', 'NonCompliant', 'Failed')]
        [string]$Status,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Detail = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Version = ''
    )

    return [pscustomobject]@{
        Key = [string](Get-ObjectValue -InputObject $Application -Name 'Key')
        Name = Get-AppDisplayName -Application $Application
        Order = [int](Get-ObjectValue -InputObject $Application -Name 'Order')
        InstallOrder = [int](Get-ObjectValue -InputObject $Application -Name 'InstallOrder' -Default (Get-ObjectValue -InputObject $Application -Name 'Order'))
        Status = $Status
        Version = $Version
        Detail = $Detail
        Application = $Application
    }
}

function Get-ExitCodeForResults {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Results
    )

    $code = 0
    foreach ($result in @($Results)) {
        switch ([string]$result.Status) {
            'NeedsProxy' { if ($code -lt 10) { $code = 10 } }
            'NeedsRestart' { if ($code -lt 10) { $code = 10 } }
            'ManualActionRequired' { if ($code -lt 10) { $code = 10 } }
            'Failed' { if ($code -lt 20) { $code = 20 } }
            'NonCompliant' { if ($code -lt 30) { $code = 30 } }
        }
    }
    return $code
}

function Show-BootstrapPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    Write-Host ''
    Write-Host ((Get-UiText -Key 'PlanTitle' -Fallback 'Execution plan') + ':') -ForegroundColor Cyan
    foreach ($result in @($Results | Sort-Object Order)) {
        Write-Host ('  [{0,-24}] {1}' -f (Get-StatusDisplayText -Status $result.Status), $result.Name)
        if ($result.Status -in @('NonCompliant', 'ManualActionRequired') -and $result.Detail) {
            Write-Host ('      {0}' -f (Protect-LogText -Text $result.Detail)) -ForegroundColor Yellow
        }
    }
}

function Confirm-BootstrapPlan {
    [CmdletBinding()]
    param([switch]$Yes)

    if ($Yes) {
        return $true
    }
    if (-not (Test-InteractiveConsole)) {
        throw [System.ArgumentException]::new('Confirmation is unavailable in a non-interactive session. Add -Yes after reviewing with -WhatIf.')
    }
    $answer = (Read-Host (Get-UiText -Key 'ContinuePrompt' -Fallback 'Continue with this plan? [y/N]')).Trim()
    return $answer -in @('y', 'yes', 'Y', 'YES')
}

function Get-SafeProxyLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyUri
    )

    try {
        $uri = [Uri]$ProxyUri
        return '{0}://{1}:{2}' -f $uri.Scheme, $uri.Host, $uri.Port
    }
    catch {
        return '<invalid proxy>'
    }
}

function Test-TcpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter()]
        [ValidateRange(100, 10000)]
        [int]$TimeoutMilliseconds = 750
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Invoke-WebRequestSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri,

        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri,

        [Parameter()]
        [AllowNull()]
        [string]$OutFile,

        [Parameter()]
        [ValidateRange(3, 300)]
        [int]$TimeoutSeconds = 15,

        [Parameter()]
        [AllowNull()]
        [string[]]$AllowedRedirectHosts
    )

    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    $oldDefaultProxy = [Net.WebRequest]::DefaultWebProxy
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
        $parameters = @{
            UseBasicParsing = $true
            TimeoutSec = $TimeoutSeconds
            ErrorAction = 'Stop'
            Headers = @{ 'User-Agent' = 'win11-bootstrap/0.1' }
        }
        if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) {
            $parameters['Proxy'] = Resolve-ProxyUriValue -Value $ProxyUri
        }
        else {
            # Windows PowerShell 5.1 otherwise inherits the system/IE proxy.
            # An empty IWebProxy makes the initial attempt genuinely direct.
            [Net.WebRequest]::DefaultWebProxy = [Net.GlobalProxySelection]::GetEmptyWebProxy()
        }
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $parameters['OutFile'] = $OutFile
            $parameters['PassThru'] = $true
        }
        $strictRedirects = $PSBoundParameters.ContainsKey('AllowedRedirectHosts')
        if (-not $strictRedirects) {
            $parameters['Uri'] = $Uri
            return Invoke-WebRequest @parameters
        }

        $allowedHosts = @(ConvertTo-StringArray $AllowedRedirectHosts | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
        if ($allowedHosts.Count -eq 0) {
            throw [System.Security.SecurityException]::new('At least one reviewed redirect host is required.')
        }

        $parameters['MaximumRedirection'] = 0
        $currentUri = $Uri
        for ($redirectCount = 0; $redirectCount -le 10; $redirectCount++) {
            if ($currentUri.Scheme -ne 'https' -or
                -not [string]::IsNullOrWhiteSpace($currentUri.UserInfo) -or
                $allowedHosts -inotcontains $currentUri.Host) {
                throw [System.Security.SecurityException]::new('The download attempted an unreviewed redirect URI.')
            }

            $parameters['Uri'] = $currentUri
            $response = $null
            $redirectResponse = $null
            try {
                $response = Invoke-WebRequest @parameters
            }
            catch {
                $exceptionCursor = $_.Exception
                while ($null -ne $exceptionCursor) {
                    if ($null -ne $exceptionCursor.PSObject.Properties['Response'] -and $null -ne $exceptionCursor.Response) {
                        $candidateStatus = [int]$exceptionCursor.Response.StatusCode
                        if ($candidateStatus -ge 300 -and $candidateStatus -lt 400) {
                            $redirectResponse = $exceptionCursor.Response
                            break
                        }
                    }
                    $exceptionCursor = $exceptionCursor.InnerException
                }
                if ($null -eq $redirectResponse) {
                    throw
                }
            }

            $statusCode = 0
            if ($null -ne $redirectResponse) {
                $statusCode = [int]$redirectResponse.StatusCode
            }
            elseif ($null -ne $response -and $null -ne $response.PSObject.Properties['StatusCode']) {
                $statusCode = [int]$response.StatusCode
            }

            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                $location = $null
                if ($null -ne $redirectResponse) {
                    $location = $redirectResponse.Headers['Location']
                }
                elseif ($null -ne $response.PSObject.Properties['Headers']) {
                    $location = $response.Headers['Location']
                }
                if ($null -ne $redirectResponse) {
                    try { $redirectResponse.Close() } catch { Write-Debug 'Redirect response cleanup failed.' }
                }
                if ([string]::IsNullOrWhiteSpace([string]$location)) {
                    throw [System.Security.SecurityException]::new('A redirect response omitted its Location header.')
                }
                if ($redirectCount -ge 10) {
                    throw [System.Security.SecurityException]::new('The download exceeded the reviewed redirect limit.')
                }
                $nextUri = $null
                if (-not [Uri]::TryCreate($currentUri, [string]$location, [ref]$nextUri)) {
                    throw [System.Security.SecurityException]::new('A redirect Location was not a valid URI.')
                }
                # Validate before issuing the next request, not merely after the
                # final response. This prevents leaking a request to an attacker
                # controlled intermediate redirect host.
                if ($nextUri.Scheme -ne 'https' -or
                    -not [string]::IsNullOrWhiteSpace($nextUri.UserInfo) -or
                    $allowedHosts -inotcontains $nextUri.Host) {
                    throw [System.Security.SecurityException]::new('The download redirected to an unreviewed host.')
                }
                $currentUri = $nextUri
                continue
            }
            return $response
        }
        throw [System.Security.SecurityException]::new('The download redirect limit was exceeded.')
    }
    finally {
        [Net.WebRequest]::DefaultWebProxy = $oldDefaultProxy
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    }
}

function Test-NetworkFailureEvidence {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$ExitCode = 0,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Output = '',

        [Parameter()]
        [AllowNull()]
        [Exception]$Exception
    )

    # Stable WinHTTP HRESULTs: timeout, name resolution failure, connection
    # failure, and connection abort. Unknown failures are deliberately not
    # treated as network failures, so they cannot authorize proxy retry.
    $networkHResults = @(-2147012894, -2147012889, -2147012867, -2147012866, -1978335098, -1978334969)
    if ($ExitCode -in $networkHResults -or $Output -match '(?i)0x(?:80072(?:EE2|EE7|EFD|EFE)|8A150(?:086|107))') {
        return $true
    }

    $current = $Exception
    while ($null -ne $current) {
        if ($current.HResult -in $networkHResults) {
            return $true
        }
        if ($current -is [Net.WebException]) {
            if ($current.Status -in @(
                [Net.WebExceptionStatus]::Timeout,
                [Net.WebExceptionStatus]::NameResolutionFailure,
                [Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [Net.WebExceptionStatus]::ConnectFailure,
                [Net.WebExceptionStatus]::ConnectionClosed,
                [Net.WebExceptionStatus]::ReceiveFailure,
                [Net.WebExceptionStatus]::SendFailure
            )) {
                return $true
            }
        }
        if ($current -is [Net.Sockets.SocketException] -or $current.GetType().FullName -eq 'System.Net.Http.HttpRequestException') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-WinGetFailureKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Output = ''
    )

    $securityCodes = @(-1978335222, -1978335215, -1978335206, -1978335187, -1978335186, -1978335169, -1978335138, -1978335136, -1978335092, -1978334962)
    if ($ExitCode -in $securityCodes -or $Output -match '(?i)0x8A150(?:00A|011|01A|02D|02E|03F|05E|060|08C|10E)') {
        return 'NonCompliant'
    }
    $restartCodes = @(-1978334967, -1978334966)
    if ($ExitCode -in $restartCodes -or $Output -match '(?i)0x8A15010(?:9|A)') {
        return 'NeedsRestart'
    }
    $manualActionCodes = @(
        -1978335205, -1978335204,
        -1978335146,
        -1978335117, -1978335116, -1978335115, -1978335114, -1978335113, -1978335112,
        -1978335107, -1978335099,
        -1978334961
    )
    if ($ExitCode -in $manualActionCodes -or $Output -match '(?i)0x8A150(?:01B|01C|056|07[3-8D]|085|10F)') {
        return 'ManualActionRequired'
    }
    if (Test-NetworkFailureEvidence -ExitCode $ExitCode -Output $Output) {
        return 'NeedsProxy'
    }
    return 'Failed'
}

function Test-DirectHttps {
    [CmdletBinding()]
    param()

    try {
        [void](Invoke-WebRequestSafe -Uri ([Uri]$script:ProxyTestUri) -TimeoutSeconds 10)
        return $true
    }
    catch {
        return $false
    }
}

function Test-ProxyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyUri
    )

    try {
        $normalized = Resolve-ProxyUriValue -Value $ProxyUri
        $uri = [Uri]$normalized
        if ($uri.Host -in @('127.0.0.1', 'localhost', '::1')) {
            if (-not (Test-TcpEndpoint -HostName $uri.Host -Port $uri.Port)) {
                return $false
            }
        }
        [void](Invoke-WebRequestSafe -Uri ([Uri]$script:ProxyTestUri) -ProxyUri $normalized -TimeoutSeconds 10)
        return $true
    }
    catch {
        return $false
    }
}

function Get-ProxyCandidates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $addCandidate = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        try {
            $normalized = Resolve-ProxyUriValue -Value $Value
            $key = $normalized.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                [void]$candidates.Add($normalized)
                $seen[$key] = $true
            }
        }
        catch { Write-Debug 'An invalid proxy candidate was ignored.' }
    }

    & $addCandidate $ExplicitProxyUri
    try {
        $testUri = [Uri]$script:ProxyTestUri
        $systemProxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy($testUri)
        if ($null -ne $systemProxy -and $systemProxy.AbsoluteUri -ne $testUri.AbsoluteUri) {
            & $addCandidate $systemProxy.AbsoluteUri
        }
    }
    catch { Write-Debug 'System proxy discovery failed.' }
    & $addCandidate 'http://127.0.0.1:7897/'
    & $addCandidate 'http://127.0.0.1:7890/'
    return @($candidates.ToArray())
}

function Invoke-WithProcessProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyUri,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $normalizedProxyUri = Resolve-ProxyUriValue -Value $ProxyUri
    $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    $previous = @{}
    $oldDefaultProxy = [Net.WebRequest]::DefaultWebProxy
    # Environment names are case-insensitive on Windows. Use one canonical
    # spelling per variable and snapshot both values before changing either.
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('HTTP_PROXY', $normalizedProxyUri, 'Process')
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $normalizedProxyUri, 'Process')
        # ALL_PROXY could override the selected transport and NO_PROXY could
        # silently bypass it. Clear both for the bounded proxied operation.
        [Environment]::SetEnvironmentVariable('ALL_PROXY', $null, 'Process')
        [Environment]::SetEnvironmentVariable('NO_PROXY', $null, 'Process')
        $webProxy = New-Object Net.WebProxy([Uri]$normalizedProxyUri)
        [Net.WebRequest]::DefaultWebProxy = $webProxy
        return & $ScriptBlock
    }
    finally {
        [Net.WebRequest]::DefaultWebProxy = $oldDefaultProxy
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}

function Invoke-WithoutProcessProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    $previous = @{}
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $oldDefaultProxy = [Net.WebRequest]::DefaultWebProxy
    try {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        [Net.WebRequest]::DefaultWebProxy = [Net.GlobalProxySelection]::GetEmptyWebProxy()
        return & $ScriptBlock
    }
    finally {
        [Net.WebRequest]::DefaultWebProxy = $oldDefaultProxy
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}

function Get-WingetCommandPath {
    [CmdletBinding()]
    param()

    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        return $null
    }
    $windowsAppsRoot = Join-Path $programFiles 'WindowsApps'
    try {
        $rootItem = Get-Item -LiteralPath $windowsAppsRoot -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $null
        }
    }
    catch {
        return $null
    }

    $packages = @()
    try {
        $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
    }
    catch {
        try {
            $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        }
        catch {
            return $null
        }
    }

    foreach ($package in @($packages | Sort-Object -Property Version -Descending)) {
        $installLocation = [string](Get-ObjectValue -InputObject $package -Name 'InstallLocation' -Default '')
        if ([string]::IsNullOrWhiteSpace($installLocation)) {
            continue
        }
        try {
            $resolvedRoot = [IO.Path]::GetFullPath($windowsAppsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $resolvedInstall = [IO.Path]::GetFullPath($installLocation).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            if (-not $resolvedInstall.StartsWith(($resolvedRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $installItem = Get-Item -LiteralPath $resolvedInstall -Force -ErrorAction Stop
            if (-not $installItem.PSIsContainer -or (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                continue
            }
            $candidate = Join-Path $resolvedInstall 'winget.exe'
            if (Test-TrustedMicrosoftExecutable -Path $candidate -ExpectedRoot $resolvedInstall) {
                return (Get-Item -LiteralPath $candidate -Force -ErrorAction Stop).FullName
            }
        }
        catch {
            continue
        }
    }
    return $null
}

function Test-WinGetSourceIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('winget', 'msstore')]
        [string]$Name
    )

    $expected = $script:TrustedWinGetSources[$Name]
    $export = Invoke-WingetRaw -Arguments @('source', 'export', $Name, '--disable-interactivity')
    if ($export.ExitCode -ne 0) {
        return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' could not be exported for identity verification.") }
    }
    try {
        $source = ConvertFrom-Json -InputObject ([string]$export.Output) -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' did not export one valid JSON object.") }
    }
    if ($null -eq $source -or $source -is [Array] -or $source -is [string]) {
        return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' did not export one valid JSON object.") }
    }

    foreach ($propertyName in @('Name', 'Arg', 'Data', 'Identifier', 'Type', 'Explicit', 'TrustLevel')) {
        if ($null -eq $source.PSObject.Properties[$propertyName]) {
            return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' omitted required identity field '$propertyName'.") }
        }
    }
    foreach ($propertyName in @('Name', 'Arg', 'Data', 'Identifier', 'Type')) {
        if ([string]$source.$propertyName -cne [string]$expected[$propertyName]) {
            return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' does not match the reviewed Microsoft $propertyName value.") }
        }
    }
    if ($source.Explicit -isnot [bool] -or [bool]$source.Explicit -ne [bool]$expected.Explicit) {
        return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' has an unreviewed Explicit setting.") }
    }

    $actualTrust = @(ConvertTo-StringArray $source.TrustLevel | Sort-Object)
    $expectedTrust = @(ConvertTo-StringArray $expected.TrustLevel | Sort-Object)
    if ($actualTrust.Count -ne $expectedTrust.Count -or (@($actualTrust) -join '|') -cne (@($expectedTrust) -join '|')) {
        return [pscustomobject]@{ Trusted = $false; Detail = ("WinGet source '$Name' does not have the exact reviewed Microsoft trust level.") }
    }
    return [pscustomobject]@{ Trusted = $true; Detail = ("WinGet source '$Name' matches the reviewed Microsoft identity.") }
}

function Test-TrustedWinGetSources {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('winget', 'msstore')]
        [string[]]$RequiredSources = @('winget', 'msstore')
    )

    foreach ($sourceName in @($RequiredSources | Select-Object -Unique)) {
        $sourceTrust = Test-WinGetSourceIdentity -Name $sourceName
        if (-not $sourceTrust.Trusted) {
            return $sourceTrust
        }
    }
    return [pscustomobject]@{ Trusted = $true; Detail = 'All required WinGet sources match the reviewed Microsoft identities.' }
}

function Test-WinGetFunctional {
    [CmdletBinding()]
    param()

    if (-not (Get-WingetCommandPath)) {
        return $false
    }
    $version = Invoke-WingetRaw -Arguments @('--version')
    if ($version.ExitCode -ne 0 -or $version.Output -notmatch '(?i)^v?\d+\.\d+') {
        return $false
    }
    return (Test-TrustedWinGetSources).Trusted
}

function Get-WinGetSourceComplianceFailure {
    [CmdletBinding()]
    param()

    if (-not (Get-WingetCommandPath)) {
        return $null
    }
    $version = Invoke-WingetRaw -Arguments @('--version')
    if ($version.ExitCode -ne 0 -or $version.Output -notmatch '(?i)^v?\d+\.\d+') {
        return $null
    }
    $sourceTrust = Test-TrustedWinGetSources
    if (-not $sourceTrust.Trusted) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = ($sourceTrust.Detail + ' Review the local source configuration and reset it manually before rerunning.') }
    }
    return $null
}

function Invoke-WingetRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri
    )

    # PSScriptAnalyzer does not count variables captured only by a nested
    # scriptblock as use in the parent scope; this documents the intentional
    # closure while preserving the command's array-valued argument contract.
    [void]$Arguments
    $winget = Get-WingetCommandPath
    if ([string]::IsNullOrWhiteSpace($winget)) {
        return [pscustomobject]@{ ExitCode = 127; Output = 'winget.exe is unavailable.' }
    }
    $runner = {
        $lines = & $winget @Arguments 2>&1
        $nativeExitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = [int]$nativeExitCode; Output = (($lines | Out-String).Trim()) }
    }
    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return & $runner
    }
    return Invoke-WithProcessProxy -ProxyUri $ProxyUri -ScriptBlock $runner
}

function Invoke-WingetDirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $enabledByUs = $false
    $result = $null
    $restoreFailed = $false
    try {
        $probe = Invoke-WingetRaw -Arguments @('source', 'list', '--disable-interactivity', '--no-proxy')
        $featureEnabled = $probe.ExitCode -eq 0
        if (-not $featureEnabled -and $probe.Output -match 'ProxyCommandLineOptions') {
            $enable = Invoke-WingetRaw -Arguments @('settings', '--enable', 'ProxyCommandLineOptions')
            $enabledByUs = $enable.ExitCode -eq 0
            $featureEnabled = $enabledByUs
        }
        if (-not $featureEnabled) {
            return [pscustomobject]@{ ExitCode = 1; Output = 'WinGet direct mode could not be verified with --no-proxy.'; SecurityFailure = $true }
        }
        $result = Invoke-WingetRaw -Arguments (@($Arguments) + @('--no-proxy'))
    }
    finally {
        if ($enabledByUs) {
            $disable = Invoke-WingetRaw -Arguments @('settings', '--disable', 'ProxyCommandLineOptions')
            $restoreFailed = $disable.ExitCode -ne 0
        }
    }
    if ($restoreFailed) {
        return [pscustomobject]@{ ExitCode = 1; Output = 'WinGet ProxyCommandLineOptions could not be restored after the direct attempt.'; SecurityFailure = $true }
    }
    return $result
}

function Invoke-WingetThroughProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$ProxyUri
    )

    $featureWasEnabled = $false
    $enabledByUs = $false
    $result = $null
    $restoreFailed = $false
    try {
        # Probe the option itself instead of parsing localized "winget
        # features" output. If the option is disabled, WinGet names the
        # stable feature identifier in its error. An unrelated probe failure
        # never authorizes changing the feature setting.
        $probe = Invoke-WingetRaw -Arguments @('source', 'list', '--disable-interactivity', '--proxy', $ProxyUri) -ProxyUri $ProxyUri
        $featureWasEnabled = $probe.ExitCode -eq 0
        if (-not $featureWasEnabled -and $probe.Output -match 'ProxyCommandLineOptions') {
            $enable = Invoke-WingetRaw -Arguments @('settings', '--enable', 'ProxyCommandLineOptions')
            $enabledByUs = $enable.ExitCode -eq 0
        }

        $proxyArguments = @($Arguments)
        if ($featureWasEnabled -or $enabledByUs) {
            $proxyArguments += @('--proxy', $ProxyUri)
            $result = Invoke-WingetRaw -Arguments $proxyArguments -ProxyUri $ProxyUri
        }
        else {
            $result = [pscustomobject]@{ ExitCode = 1; Output = 'WinGet explicit proxy mode could not be enabled safely.'; SecurityFailure = $true }
        }
    }
    finally {
        if ($enabledByUs) {
            $disable = Invoke-WingetRaw -Arguments @('settings', '--disable', 'ProxyCommandLineOptions')
            $restoreFailed = $disable.ExitCode -ne 0
        }
    }
    if ($restoreFailed) {
        return [pscustomobject]@{ ExitCode = 1; Output = 'WinGet ProxyCommandLineOptions could not be restored after proxy use.'; SecurityFailure = $true }
    }
    return $result
}

function Invoke-WingetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri
    )

    $installerType = [string](Get-ObjectValue -InputObject $Application -Name 'InstallerType')
    $packageId = [string](Get-ObjectValue -InputObject $Application -Name 'WingetId' -Default '')
    if ($installerType -eq 'Store') {
        $packageId = [string](Get-ObjectValue -InputObject $Application -Name 'StoreProductId' -Default $packageId)
    }
    if ([string]::IsNullOrWhiteSpace($packageId)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'No WinGet package identifier is cataloged.' }
    }

    $arguments = @(
        'install', '--id', $packageId, '--exact', '--silent', '--no-upgrade',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    $source = [string](Get-ObjectValue -InputObject $Application -Name 'WingetSource' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($source)) {
        $arguments += @('--source', $source)
    }
    $version = [string](Get-ObjectValue -InputObject $Application -Name 'WingetVersion' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        $arguments += @('--version', $version)
    }

    if ($source -notin @('winget', 'msstore')) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = 'The catalog did not select one reviewed Microsoft WinGet source.' }
    }
    $sourceTrust = Test-TrustedWinGetSources -RequiredSources @($source)
    if (-not $sourceTrust.Trusted) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $sourceTrust.Detail }
    }

    Write-BootstrapLog -Message ("Installing {0} from the reviewed WinGet catalog entry..." -f (Get-ObjectValue -InputObject $Application -Name 'Name'))
    $direct = Invoke-WingetDirect -Arguments $arguments
    if ([bool](Get-ObjectValue -InputObject $direct -Name 'SecurityFailure' -Default $false)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $direct.Output }
    }
    if ($direct.ExitCode -eq 0) {
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet completed successfully using the direct path.' }
    }
    $directFailureKind = Get-WinGetFailureKind -ExitCode $direct.ExitCode -Output $direct.Output
    if ($directFailureKind -eq 'NonCompliant') {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = ('WinGet reported a security or integrity failure for package {0}.' -f $packageId) }
    }
    if ($directFailureKind -eq 'NeedsRestart') {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsRestart'; Detail = ('WinGet requires a manual restart before package {0} can finish.' -f $packageId) }
    }
    if ($directFailureKind -eq 'ManualActionRequired') {
        return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Detail = ('WinGet requires an account sign-in, license acceptance, interactive action, or policy change before package {0} can be installed.' -f $packageId) }
    }
    $postDirectDetection = Test-AppInstalled -Application $Application
    if ($postDirectDetection.NonCompliant) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $postDirectDetection.Detail }
    }
    if ($postDirectDetection.Installed) {
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet returned a nonzero code, but exact post-install detection confirms the package is installed.' }
    }
    if ($directFailureKind -ne 'NeedsProxy') {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = ('WinGet failed for package {0} without verified network-failure evidence; proxy retry was refused.' -f $packageId) }
    }

    $workingProxyFound = $false
    foreach ($candidate in (Get-ProxyCandidates -ExplicitProxyUri $ExplicitProxyUri)) {
        if (-not (Test-ProxyUri -ProxyUri $candidate)) {
            continue
        }
        $workingProxyFound = $true
        Write-BootstrapLog -Message ('Retrying through verified process-scoped proxy {0}.' -f (Get-SafeProxyLabel -ProxyUri $candidate)) -Level Warning
        $sourceTrust = Test-TrustedWinGetSources -RequiredSources @($source)
        if (-not $sourceTrust.Trusted) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $sourceTrust.Detail }
        }
        $proxied = Invoke-WingetThroughProxy -Arguments $arguments -ProxyUri $candidate
        if ([bool](Get-ObjectValue -InputObject $proxied -Name 'SecurityFailure' -Default $false)) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $proxied.Output }
        }
        if ($proxied.ExitCode -eq 0) {
            return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet completed successfully through a verified process-scoped proxy.' }
        }
        $proxyFailureKind = Get-WinGetFailureKind -ExitCode $proxied.ExitCode -Output $proxied.Output
        if ($proxyFailureKind -eq 'NonCompliant') {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = ('WinGet reported a security or integrity failure for package {0} through the proxy.' -f $packageId) }
        }
        if ($proxyFailureKind -eq 'NeedsRestart') {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsRestart'; Detail = ('WinGet requires a manual restart before package {0} can finish.' -f $packageId) }
        }
        if ($proxyFailureKind -eq 'ManualActionRequired') {
            return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Detail = ('WinGet requires an account sign-in, license acceptance, interactive action, or policy change before package {0} can be installed.' -f $packageId) }
        }
        $postProxyDetection = Test-AppInstalled -Application $Application
        if ($postProxyDetection.NonCompliant) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $postProxyDetection.Detail }
        }
        if ($postProxyDetection.Installed) {
            return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'Exact post-install detection confirms the package is installed.' }
        }
        if ($proxyFailureKind -ne 'NeedsProxy') {
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = ('WinGet failed for package {0} through a verified proxy with a non-network error.' -f $packageId) }
        }
    }

    if (-not $workingProxyFound) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Detail = 'Direct HTTPS and all allowed proxy candidates failed. Configure Clash and rerun.' }
    }
    return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Detail = ('All allowed transports produced verified network failures for package {0}. Configure or repair the proxy path, then rerun.' -f $packageId) }
}

function Invoke-WinGetRepairModuleCore {
    [CmdletBinding()]
    param()

    try {
        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            return $false
        }
        $moduleRoot = Join-Path $programFiles 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
        $rootItem = Get-Item -LiteralPath $moduleRoot -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }

        $versionRoot = Join-Path $moduleRoot $script:WinGetClientVersion
        $versionItem = Get-Item -LiteralPath $versionRoot -Force -ErrorAction Stop
        if (-not $versionItem.PSIsContainer -or (($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $manifest = Join-Path $versionItem.FullName 'Microsoft.WinGet.Client.psd1'
        $manifestItem = Get-Item -LiteralPath $manifest -Force -ErrorAction Stop
        if ($manifestItem.PSIsContainer -or (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $candidate = $manifestItem.FullName

        Microsoft.PowerShell.Core\Remove-Module -Name 'Microsoft.WinGet.Client' -Force -ErrorAction SilentlyContinue
        $imported = Microsoft.PowerShell.Core\Import-Module -Name $candidate -Force -PassThru -ErrorAction Stop
        $expectedModuleBase = [IO.Path]::GetFullPath((Split-Path -Parent $candidate)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $actualModuleBase = [IO.Path]::GetFullPath([string]$imported.ModuleBase).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not [string]::Equals($expectedModuleBase, $actualModuleBase, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        if ([string]$imported.Version -ne $script:WinGetClientVersion) {
            return $false
        }
        $repair = Get-Command -Name 'Repair-WinGetPackageManager' -Module 'Microsoft.WinGet.Client' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $repair -or $null -eq $repair.Module -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$repair.Module.ModuleBase).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $expectedModuleBase, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        & $repair -AllUsers -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-WinGetRepairWithModule {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri
    )

    $operation = { Invoke-WinGetRepairModuleCore }
    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return Invoke-WithoutProcessProxy -ScriptBlock $operation
    }
    return Invoke-WithProcessProxy -ProxyUri $ProxyUri -ScriptBlock $operation
}

function Install-WinGetRepairModule {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri
    )

    $operation = {
        $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
            $repository = PowerShellGet\Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
            $sourceUri = [Uri]([string]$repository.SourceLocation)
            $expectedUri = [Uri]'https://www.powershellgallery.com/api/v2'
            if ($sourceUri.Scheme -ne 'https' -or $sourceUri.Host -ine $expectedUri.Host -or
                $sourceUri.AbsolutePath.TrimEnd('/') -ine $expectedUri.AbsolutePath.TrimEnd('/') -or
                -not [string]::IsNullOrWhiteSpace($sourceUri.UserInfo) -or
                -not [string]::IsNullOrWhiteSpace($sourceUri.Query) -or
                -not [string]::IsNullOrWhiteSpace($sourceUri.Fragment)) {
                return [pscustomobject]@{ Success = $false; NetworkFailure = $false; Detail = 'The PSGallery registration does not point to the reviewed official HTTPS endpoint.' }
            }
            # Do not preinstall an unpinned NuGet provider. PowerShellGet must
            # either use its trusted available provider or fail closed.
            PowerShellGet\Install-Module -Name Microsoft.WinGet.Client -RequiredVersion $script:WinGetClientVersion -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
            return [pscustomobject]@{ Success = $true; NetworkFailure = $false; Detail = 'The reviewed WinGet client repair module was installed.' }
        }
        catch {
            return [pscustomobject]@{ Success = $false; NetworkFailure = (Test-NetworkFailureEvidence -Exception $_.Exception); Detail = 'The reviewed WinGet client repair module could not be installed.' }
        }
        finally {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return Invoke-WithoutProcessProxy -ScriptBlock $operation
    }
    return Invoke-WithProcessProxy -ProxyUri $ProxyUri -ScriptBlock $operation
}

function Repair-WinGetAvailability {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri
    )

    if (Test-WinGetFunctional) {
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet is available.' }
    }
    $sourceFailure = Get-WinGetSourceComplianceFailure
    if ($null -ne $sourceFailure) {
        return $sourceFailure
    }

    Write-BootstrapLog -Message 'WinGet is unavailable; attempting the approved App Installer recovery sequence.' -Level Warning
    try {
        $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $package) {
            $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $package -and -not [string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) {
            $manifest = Join-Path $package.InstallLocation 'AppxManifest.xml'
            if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue
            }
            $resetCommand = Get-Command -Name 'Reset-AppxPackage' -ErrorAction SilentlyContinue
            if ($null -ne $resetCommand) {
                $package | Reset-AppxPackage -ErrorAction SilentlyContinue
            }
        }
    }
    catch { Write-Debug 'App Installer re-registration did not complete.' }
    if (Test-WinGetFunctional) {
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet was restored by re-registering App Installer.' }
    }
    $sourceFailure = Get-WinGetSourceComplianceFailure
    if ($null -ne $sourceFailure) { return $sourceFailure }

    if (Invoke-WinGetRepairWithModule -ProxyUri $null) {
        if (Test-WinGetFunctional) {
            return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet was restored by Microsoft.WinGet.Client.' }
        }
        $sourceFailure = Get-WinGetSourceComplianceFailure
        if ($null -ne $sourceFailure) { return $sourceFailure }
    }

    $moduleInstall = Install-WinGetRepairModule -ProxyUri $null
    if ($moduleInstall.Success) {
        if ((Invoke-WinGetRepairWithModule -ProxyUri $null) -and (Test-WinGetFunctional)) {
            return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet was repaired using the reviewed Microsoft.WinGet.Client version.' }
        }
        $sourceFailure = Get-WinGetSourceComplianceFailure
        if ($null -ne $sourceFailure) { return $sourceFailure }
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'The reviewed repair module installed, but WinGet remained unavailable; proxy retry was refused.' }
    }
    if (-not $moduleInstall.NetworkFailure) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = $moduleInstall.Detail }
    }

    $workingProxyFound = $false
    foreach ($candidate in (Get-ProxyCandidates -ExplicitProxyUri $ExplicitProxyUri)) {
        if (-not (Test-ProxyUri -ProxyUri $candidate)) {
            continue
        }
        $workingProxyFound = $true
        Write-BootstrapLog -Message ('Retrying WinGet recovery through verified process-scoped proxy {0}.' -f (Get-SafeProxyLabel -ProxyUri $candidate)) -Level Warning
        $proxiedInstall = Install-WinGetRepairModule -ProxyUri $candidate
        if ($proxiedInstall.Success) {
            if ((Invoke-WinGetRepairWithModule -ProxyUri $candidate) -and (Test-WinGetFunctional)) {
                return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WinGet was repaired through a verified process-scoped proxy.' }
            }
            $sourceFailure = Get-WinGetSourceComplianceFailure
            if ($null -ne $sourceFailure) { return $sourceFailure }
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'The reviewed repair module installed through the proxy, but WinGet remained unavailable.' }
        }
        if (-not $proxiedInstall.NetworkFailure) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = $proxiedInstall.Detail }
        }
    }

    if (Get-WingetCommandPath) {
        $sourceTrust = Test-TrustedWinGetSources
        if (-not $sourceTrust.Trusted) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = $sourceTrust.Detail }
        }
    }
    if (-not $workingProxyFound) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Detail = 'WinGet and PSGallery could not be reached. Configure Clash, then rerun.' }
    }
    return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Detail = 'Every allowed WinGet repair transport ended with verified network-failure evidence. Configure or repair the proxy path, then rerun.' }
}

function Test-InstallerTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSignerSubject
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Installer file does not exist.' }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return [pscustomobject]@{ Trusted = $false; Detail = 'Installer file must not be a directory or reparse point.' }
        }
    }
    catch {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Installer file metadata could not be read safely.' }
    }
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        return [pscustomobject]@{ Trusted = $false; Detail = 'No valid reviewed SHA-256 is cataloged.' }
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSignerSubject)) {
        return [pscustomobject]@{ Trusted = $false; Detail = 'No reviewed Authenticode signer is cataloged.' }
    }

    try {
        $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Installer SHA-256 could not be calculated.' }
    }
    if ($actualHash -ine $ExpectedSha256) {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Installer SHA-256 does not match the reviewed catalog value.' }
    }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Installer Authenticode signature could not be read.' }
    }
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        return [pscustomobject]@{ Trusted = $false; Detail = ('Authenticode signature is not valid: {0}.' -f $signature.Status) }
    }
    if (-not [string]::Equals([string]$signature.SignerCertificate.Subject, $ExpectedSignerSubject, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Trusted = $false; Detail = 'Authenticode signer does not match the reviewed publisher.' }
    }
    return [pscustomobject]@{ Trusted = $true; Detail = 'SHA-256 and Authenticode signer are valid.' }
}

function Get-DirectInstallerMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter()]
        [string]$PropertyName = 'DirectInstaller'
    )

    $metadata = Get-ObjectValue -InputObject $Application -Name $PropertyName -Default $null
    if ($null -eq $metadata -and $PropertyName -eq 'DirectInstaller') {
        $metadata = Get-ObjectValue -InputObject $Application -Name 'Installer' -Default $null
    }
    if ($null -eq $metadata -and $PropertyName -eq 'DirectInstaller') {
        $metadata = Get-ObjectValue -InputObject $Application -Name 'Seed' -Default $null
    }
    return $metadata
}

function ConvertTo-NativeArgumentText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Apply the CommandLineToArgvW quoting rules used by Windows installers:
    # escape quotes and double trailing backslashes before the closing quote.
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function New-RestrictedDirectorySecurity {
    [CmdletBinding()]
    param()

    $administrators = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $system = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($identity in @($administrators, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)
        [void]$security.AddAccessRule($rule)
    }
    return $security
}

function Assert-SecureDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [Security.AccessControl.DirectorySecurity]$ExpectedSecurity
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [System.Security.SecurityException]::new("Secure bootstrap path is not a regular directory: '$Path'.")
    }
    $actual = $item.GetAccessControl([Security.AccessControl.AccessControlSections]'Access, Owner')
    if (-not $actual.AreAccessRulesProtected) {
        throw [System.Security.SecurityException]::new("Secure bootstrap ACL still inherits access rules: '$Path'.")
    }
    $expectedOwner = $ExpectedSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $actualOwner = $actual.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($actualOwner -ne $expectedOwner) {
        throw [System.Security.SecurityException]::new("Secure bootstrap owner is unexpected: '$Path'.")
    }
    $requiredSids = @{
        ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value = $false
        ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value = $false
    }
    $rules = @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $requiredSids.Count) {
        throw [System.Security.SecurityException]::new("Secure bootstrap ACL rule count is unexpected: '$Path'.")
    }
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if (-not $requiredSids.ContainsKey($sid) -or $requiredSids[$sid] -or $rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw [System.Security.SecurityException]::new("Secure bootstrap ACL is not the exact reviewed policy: '$Path'.")
        }
        $requiredSids[$sid] = $true
    }
    if (@($requiredSids.Values | Where-Object { -not $_ }).Count -ne 0) {
        throw [System.Security.SecurityException]::new("Secure bootstrap ACL is missing a required principal: '$Path'.")
    }
    return $item.FullName
}

function Get-BootstrapProgramDataPath {
    [CmdletBinding()]
    param()

    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw [System.Security.SecurityException]::new('ProgramData could not be resolved for secure bootstrap state.')
    }
    return Assert-RegularBootstrapDirectory -Path $programData
}

function New-SecureBootstrapSubdirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Logs', 'Staging', 'Runtime')]
        [string]$Name
    )

    $programData = Get-BootstrapProgramDataPath
    $security = New-RestrictedDirectorySecurity
    $productRoot = Join-Path $programData 'Win11Bootstrap'
    $subdirectory = Join-Path $productRoot $Name
    foreach ($path in @($productRoot, $subdirectory)) {
        if (-not [IO.Directory]::Exists($path)) {
            [void][IO.Directory]::CreateDirectory($path, $security)
        }
        [void](Assert-SecureDirectory -Path $path -ExpectedSecurity $security)
    }
    return (Get-Item -LiteralPath $subdirectory -Force -ErrorAction Stop).FullName
}

function New-SecureStagingDirectory {
    [CmdletBinding()]
    param()

    $stagingRoot = New-SecureBootstrapSubdirectory -Name 'Staging'
    $security = New-RestrictedDirectorySecurity

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $leaf = [Guid]::NewGuid().ToString('N')
        $path = Join-Path $stagingRoot $leaf
        if ([IO.Directory]::Exists($path) -or [IO.File]::Exists($path)) {
            continue
        }
        try {
            [void][IO.Directory]::CreateDirectory($path, $security)
            $validated = Assert-SecureDirectory -Path $path -ExpectedSecurity $security
            if (@(Get-ChildItem -LiteralPath $validated -Force -ErrorAction Stop).Count -ne 0) {
                throw [System.Security.SecurityException]::new('A newly-created secure staging directory was not empty.')
            }
            return $validated
        }
        catch [System.IO.IOException] {
            continue
        }
    }
    throw [System.Security.SecurityException]::new('A unique secure installer staging directory could not be created.')
}

function Test-SecureStagedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$StageDirectory
    )

    try {
        $stageItem = Get-Item -LiteralPath $StageDirectory -Force -ErrorAction Stop
        $fileItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $stageItem.PSIsContainer -or (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $fileItem.PSIsContainer -or (($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $expectedParent = [IO.Path]::GetFullPath($stageItem.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $actualParent = [IO.Path]::GetFullPath($fileItem.DirectoryName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        return [string]::Equals($expectedParent, $actualParent, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Assert-SecureRemovalTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw [System.Security.SecurityException]::new('Refusing recursive cleanup of a reparse point or non-directory path.')
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [System.Security.SecurityException]::new('Refusing recursive cleanup of a tree containing a reparse point.')
        }
    }
    return $true
}

function Remove-SecureStagingDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $stagingRoot = [IO.Path]::GetFullPath((Join-Path $programData 'Win11Bootstrap\Staging')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $target = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($target), $stagingRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($target) -notmatch '^[a-f0-9]{32}$') {
            throw [System.Security.SecurityException]::new('Refusing to clean a path outside the secure staging root.')
        }
        $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            return
        }
        [void](Assert-SecureRemovalTree -Path $target)
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    }
    catch [System.Security.SecurityException] {
        Write-BootstrapLog -Message 'Secure staging cleanup was refused by the non-reparse security boundary.' -Level Warning
        throw
    }
    catch {
        Write-BootstrapLog -Message 'Secure staging cleanup failed and the directory was left untouched.' -Level Warning
        throw [System.Security.SecurityException]::new('Secure staging cleanup failed closed.', $_.Exception)
    }
}

function Test-GitHubReleaseAssetUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri
    )

    return $Uri.Scheme -eq 'https' -and
        $Uri.Host -ieq 'github.com' -and
        $Uri.AbsolutePath -match '/releases/download/'
}

function Save-DownloadAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedResponseHosts
    )

    try {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        }
        $response = Invoke-WebRequestSafe -Uri $Uri -ProxyUri $ProxyUri -OutFile $Destination -TimeoutSeconds 120 -AllowedRedirectHosts $AllowedResponseHosts
        $responseUri = $null
        if ($null -ne $response -and $null -ne $response.BaseResponse) {
            $responseUri = $response.BaseResponse.ResponseUri
        }
        if ($null -eq $responseUri -or $responseUri.Scheme -ne 'https' -or $AllowedResponseHosts -inotcontains $responseUri.Host) {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            return [pscustomobject]@{ Success = $false; NetworkFailure = $false; SecurityFailure = $true; Detail = 'The download redirected to an unreviewed response host.' }
        }
        return [pscustomobject]@{ Success = (Test-Path -LiteralPath $Destination -PathType Leaf); NetworkFailure = $false; SecurityFailure = $false; Detail = '' }
    }
    catch {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        $securityFailure = $_.Exception -is [System.Security.SecurityException]
        return [pscustomobject]@{
            Success = $false
            NetworkFailure = $(if ($securityFailure) { $false } else { Test-NetworkFailureEvidence -Exception $_.Exception })
            SecurityFailure = $securityFailure
            Detail = $(if ($securityFailure) { $_.Exception.Message } else { 'The installer request failed.' })
        }
    }
}

function Get-VerifiedInstallerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter()]
        [AllowNull()]
        [string]$SeedDirectory,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri,

        [Parameter()]
        [switch]$NoGitHubMirrors,

        [Parameter()]
        [AllowNull()]
        [object]$Catalog
    )

    $fileName = [string](Get-ObjectValue -InputObject $Metadata -Name 'FileName' -Default '')
    $expectedHash = [string](Get-ObjectValue -InputObject $Metadata -Name 'Sha256' -Default '')
    $expectedSigner = [string](Get-ObjectValue -InputObject $Metadata -Name 'SignerSubject' -Default '')
    if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -ne [IO.Path]::GetFileName($fileName)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Path = $null; StageDirectory = $null; Detail = 'No safe installer filename is cataloged.' }
    }
    if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($expectedSigner)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Path = $null; StageDirectory = $null; Detail = 'Immutable SHA-256 and Authenticode signer metadata are required.' }
    }

    $context = [pscustomobject]@{
        StageDirectory = $null
        SeedDirectory = $SeedDirectory
        ExplicitProxyUri = $ExplicitProxyUri
        NoGitHubMirrors = [bool]$NoGitHubMirrors
        Catalog = $Catalog
    }
    $operation = {
        try {
        $stageDirectory = New-SecureStagingDirectory
        $context.StageDirectory = $stageDirectory
        $destination = Join-Path $stageDirectory $fileName

        if (-not [string]::IsNullOrWhiteSpace([string]$context.SeedDirectory)) {
            $seedPath = Join-Path ([string]$context.SeedDirectory) $fileName
            if (Test-Path -LiteralPath $seedPath -PathType Leaf) {
                try {
                    $seedItem = Get-Item -LiteralPath $seedPath -Force -ErrorAction Stop
                    if ($seedItem.PSIsContainer -or (($seedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = 'The seed installer must be a regular file, not a reparse point.' }
                    }
                    [IO.File]::Copy($seedPath, $destination, $false)
                }
                catch {
                    return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Path = $null; StageDirectory = $null; Detail = 'The seed installer could not be copied into secure staging.' }
                }
                if (-not (Test-SecureStagedFile -Path $destination -StageDirectory $stageDirectory)) {
                    return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = 'The staged seed installer is a reparse point or escaped secure staging.' }
                }
                $seedTrust = Test-InstallerTrust -Path $destination -ExpectedSha256 $expectedHash -ExpectedSignerSubject $expectedSigner
                if ($seedTrust.Trusted) {
                    return [pscustomobject]@{ Success = $true; FailureKind = ''; Path = $destination; StageDirectory = $stageDirectory; Detail = 'A seed installer was staged and passed SHA-256 and Authenticode verification.' }
                }
                return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = $seedTrust.Detail }
            }
        }

        $urlText = [string](Get-ObjectValue -InputObject $Metadata -Name 'Url' -Default '')
        $officialUri = $null
        if ([string]::IsNullOrWhiteSpace($urlText) -or -not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$officialUri) -or $officialUri.Scheme -ne 'https') {
            return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Path = $null; StageDirectory = $null; Detail = 'No reviewed HTTPS installer URL is cataloged and no matching seed was found.' }
        }

        $attempts = New-Object System.Collections.Generic.List[object]
        $reviewedResponseHosts = New-Object System.Collections.Generic.List[string]
        [void]$reviewedResponseHosts.Add($officialUri.Host)
        foreach ($hostName in (ConvertTo-StringArray (Get-ObjectValue -InputObject $Metadata -Name 'AllowedRedirectHosts' -Default @()))) {
            if ($hostName -match '^[A-Za-z0-9.-]+$') {
                [void]$reviewedResponseHosts.Add($hostName)
            }
        }
        [void]$attempts.Add([pscustomobject]@{ Uri = $officialUri; Proxy = $null; AllowedHosts = @($reviewedResponseHosts | Select-Object -Unique); ValidateProxy = $false })
        foreach ($proxy in (Get-ProxyCandidates -ExplicitProxyUri ([string]$context.ExplicitProxyUri))) {
            [void]$attempts.Add([pscustomobject]@{ Uri = $officialUri; Proxy = $proxy; AllowedHosts = @($reviewedResponseHosts | Select-Object -Unique); ValidateProxy = $true })
        }

        if (-not $context.NoGitHubMirrors -and (Test-GitHubReleaseAssetUri -Uri $officialUri)) {
            $catalogMirrorHosts = ConvertTo-StringArray (Get-ObjectValue -InputObject $context.Catalog -Name 'MirrorHosts' -Default @())
            foreach ($mirrorHost in @('ghfast.top', 'gh-proxy.com')) {
                if ($catalogMirrorHosts -notcontains $mirrorHost) {
                    continue
                }
                $mirrorUri = [Uri]('https://{0}/{1}' -f $mirrorHost, $officialUri.AbsoluteUri)
                [void]$attempts.Add([pscustomobject]@{ Uri = $mirrorUri; Proxy = $null; AllowedHosts = @($mirrorHost); ValidateProxy = $false })
            }
        }

        $networkAttempted = $false
        foreach ($attempt in $attempts) {
            if ($attempt.ValidateProxy -and -not (Test-ProxyUri -ProxyUri $attempt.Proxy)) {
                continue
            }
            $networkAttempted = $true
            $download = Save-DownloadAttempt -Uri $attempt.Uri -Destination $destination -ProxyUri $attempt.Proxy -AllowedResponseHosts $attempt.AllowedHosts
            if (-not $download.Success) {
                if ($download.SecurityFailure) {
                    return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = $download.Detail }
                }
                if (-not $download.NetworkFailure) {
                    return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Path = $null; StageDirectory = $null; Detail = $download.Detail }
                }
                continue
            }
            if (-not (Test-SecureStagedFile -Path $destination -StageDirectory $stageDirectory)) {
                return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = 'The downloaded installer is a reparse point or escaped secure staging.' }
            }
            $trust = Test-InstallerTrust -Path $destination -ExpectedSha256 $expectedHash -ExpectedSignerSubject $expectedSigner
            if ($trust.Trusted) {
                return [pscustomobject]@{ Success = $true; FailureKind = ''; Path = $destination; StageDirectory = $stageDirectory; Detail = 'The staged download passed SHA-256 and Authenticode verification.' }
            }
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = $trust.Detail }
        }

        if ($networkAttempted) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Path = $null; StageDirectory = $null; Detail = 'The reviewed installer could not be downloaded directly or through a verified proxy.' }
        }
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Path = $null; StageDirectory = $null; Detail = 'The reviewed installer download failed.' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; StageDirectory = $null; Detail = ('Secure installer staging failed closed: {0}' -f $_.Exception.Message) }
    }
    }
    $outcome = & $operation
    if (-not $outcome.Success -and -not [string]::IsNullOrWhiteSpace([string]$context.StageDirectory)) {
        Remove-SecureStagingDirectory -Path ([string]$context.StageDirectory)
    }
    return $outcome
}

function Install-DirectApplicationCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter()]
        [AllowNull()]
        [string]$SeedDirectory,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri,

        [Parameter()]
        [switch]$NoGitHubMirrors,

        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    $applicationName = [string](Get-ObjectValue -InputObject $Application -Name 'Name' -Default 'application')
    $installer = Get-VerifiedInstallerFile -Metadata $Metadata -SeedDirectory $SeedDirectory -ExplicitProxyUri $ExplicitProxyUri -NoGitHubMirrors:$NoGitHubMirrors -Catalog $Catalog
    if (-not $installer.Success) {
        return $installer
    }

    $stageDirectory = [string]$installer.StageDirectory
    $operation = {
        try {
        if (-not (Test-SecureStagedFile -Path ([string]$installer.Path) -StageDirectory $stageDirectory)) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; Detail = 'The installer left secure staging or became a reparse point before execution.' }
        }
        $expectedHash = [string](Get-ObjectValue -InputObject $Metadata -Name 'Sha256' -Default '')
        $expectedSigner = [string](Get-ObjectValue -InputObject $Metadata -Name 'SignerSubject' -Default '')

        $extension = [IO.Path]::GetExtension([string]$installer.Path).ToLowerInvariant()
        if ($extension -notin @('.exe', '.msi')) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; Detail = 'Only reviewed EXE and MSI installer formats may execute.' }
        }
        $silentArgs = @(ConvertTo-StringArray (Get-ObjectValue -InputObject $Metadata -Name 'SilentArgs' -Default @()))
        $filePath = [string]$installer.Path
        $argumentList = @($silentArgs)
        if ($extension -eq '.msi') {
            $filePath = Get-TrustedSystemExecutablePath -RelativePath 'msiexec.exe'
            $argumentList = @('/i', [string]$installer.Path, '/qn', '/norestart') + @($silentArgs)
        }
        elseif ($silentArgs.Count -eq 0) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Path = $null; Detail = 'No reviewed silent installer arguments are cataloged.' }
        }

        # Repeat both location and identity checks immediately before starting
        # the process. Acquisition-time validation alone would leave a TOCTOU
        # window between staging and execution.
        if (-not (Test-SecureStagedFile -Path ([string]$installer.Path) -StageDirectory $stageDirectory)) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; Detail = 'The installer left secure staging or became a reparse point before execution.' }
        }
        $finalTrust = Test-InstallerTrust -Path ([string]$installer.Path) -ExpectedSha256 $expectedHash -ExpectedSignerSubject $expectedSigner
        if (-not $finalTrust.Trusted) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; Detail = ('Final pre-execution trust verification failed: {0}' -f $finalTrust.Detail) }
        }
        $nativeArgumentText = (@($argumentList | ForEach-Object { ConvertTo-NativeArgumentText -Argument ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath $filePath -ArgumentList $nativeArgumentText -WorkingDirectory $stageDirectory -Wait -PassThru -ErrorAction Stop
        $acceptedCodes = @(0, 3010)
        $configuredCodes = Get-ObjectValue -InputObject $Metadata -Name 'SuccessExitCodes' -Default $null
        if ($null -ne $configuredCodes) {
            $acceptedCodes = @($configuredCodes | ForEach-Object { [int]$_ })
        }
        if ([int]$process.ExitCode -notin $acceptedCodes) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Path = $null; Detail = ('Installer exited with code {0}.' -f $process.ExitCode) }
        }
        if ([int]$process.ExitCode -eq 3010) {
            return [pscustomobject]@{ Success = $true; FailureKind = 'NeedsRestart'; Path = $null; Detail = 'Installation succeeded and requested a restart; the script did not restart Windows.' }
        }
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Path = $null; Detail = 'Verified installer completed successfully.' }
    }
    catch [System.Security.SecurityException] {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Path = $null; Detail = ("The verified installer execution boundary rejected unsafe system state for '{0}'." -f $applicationName) }
    }
    catch {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Path = $null; Detail = ("Unable to start the verified installer for '{0}': {1}" -f $applicationName, $_.Exception.Message) }
    }
    }
    $outcome = & $operation
    if (-not [string]::IsNullOrWhiteSpace($stageDirectory)) {
        Remove-SecureStagingDirectory -Path $stageDirectory
    }
    return $outcome
}

function Install-DirectApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter()]
        [AllowNull()]
        [string]$SeedDirectory,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri,

        [Parameter()]
        [switch]$NoGitHubMirrors,

        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    try {
        return Install-DirectApplicationCore -Application $Application -Metadata $Metadata -SeedDirectory $SeedDirectory -ExplicitProxyUri $ExplicitProxyUri -NoGitHubMirrors:$NoGitHubMirrors -Catalog $Catalog
    }
    catch [System.Security.SecurityException] {
        return [pscustomobject]@{
            Success = $false
            FailureKind = 'NonCompliant'
            Path = $null
            Detail = 'Secure staging cleanup was refused or failed; the staging tree was not followed or reused.'
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            FailureKind = 'Failed'
            Path = $null
            Detail = 'The direct installer provider failed before it could return a stable result.'
        }
    }
}

function Invoke-WslInstallCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distribution,

        [Parameter()]
        [AllowNull()]
        [string]$ProxyUri
    )

    try {
        $wslPath = Get-TrustedSystemExecutablePath -RelativePath 'wsl.exe'
    }
    catch [System.IO.FileNotFoundException] {
        return [pscustomobject]@{ ExitCode = 126; Output = 'The system wsl.exe is not installed.'; SecurityFailure = $false }
    }
    catch [System.Security.SecurityException] {
        return [pscustomobject]@{ ExitCode = 126; Output = 'The system wsl.exe failed trusted path or signature validation.'; SecurityFailure = $true }
    }
    catch {
        return [pscustomobject]@{ ExitCode = 126; Output = 'The system wsl.exe could not be resolved.'; SecurityFailure = $false }
    }
    $arguments = @('--install', '--distribution', $Distribution, '--no-launch')
    if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) {
        # The Store transport does not consistently honor process proxy state.
        # The proxied retry therefore uses WSL's official web-download path.
        $arguments += '--web-download'
    }
    $operation = {
        $output = & $wslPath @arguments 2>&1
        return [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = (($output | Out-String).Trim()); SecurityFailure = $false }
    }
    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return Invoke-WithoutProcessProxy -ScriptBlock $operation
    }
    return Invoke-WithProcessProxy -ProxyUri $ProxyUri -ScriptBlock $operation
}

function Install-WslApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri
    )

    $restartNeeded = $false
    foreach ($featureName in (ConvertTo-StringArray (Get-ObjectValue -InputObject $Application -Name 'WindowsFeatures' -Default @()))) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
            if ($feature.State -ne 'Enabled') {
                Write-BootstrapLog -Message ("Enabling Windows feature '$featureName' without restarting...")
                $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop
                if ([bool](Get-ObjectValue -InputObject $enableResult -Name 'RestartNeeded' -Default $false)) {
                    $restartNeeded = $true
                }
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
                if ($feature.State -ne 'Enabled') {
                    $restartNeeded = $true
                }
            }
        }
        catch {
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = ("Unable to enable Windows feature '$featureName': {0}" -f $_.Exception.Message) }
        }
    }
    if ($restartNeeded) {
        return [pscustomobject]@{ Success = $true; FailureKind = 'NeedsRestart'; Detail = 'WSL features were enabled. Restart Windows manually, then rerun.' }
    }

    $detection = Get-ObjectValue -InputObject $Application -Name 'Detection' -Default @{}
    $distribution = [string](Get-ObjectValue -InputObject $detection -Name 'WslDistribution' -Default '')
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'No WSL distribution is cataloged.' }
    }
    $existingDistributions = @(Get-WslDistributions)
    if (@($existingDistributions | Where-Object { $_.Name -ieq $distribution -and $_.Version -eq 2 }).Count -gt 0) {
        return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'The requested WSL distribution is already installed.' }
    }
    if (@($existingDistributions | Where-Object { $_.Name -ieq $distribution -and $_.Version -ne 2 }).Count -gt 0) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'ManualActionRequired'; Detail = 'The requested distribution exists but is not WSL 2. Convert it with wsl.exe --set-version before rerunning.' }
    }

    try {
        $wslPath = Get-TrustedSystemExecutablePath -RelativePath 'wsl.exe'
        $setDefaultOutput = & $wslPath --set-default-version 2 2>&1
        $setDefaultExitCode = [int]$LASTEXITCODE
    }
    catch [System.Security.SecurityException] {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = 'The system wsl.exe failed trusted path or signature validation.' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'A trusted system wsl.exe could not set WSL 2 as the default.' }
    }
    if ($setDefaultExitCode -ne 0) {
        Write-BootstrapLog -Message ('wsl.exe --set-default-version failed: {0}' -f (($setDefaultOutput | Out-String).Trim())) -Level Warning
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'wsl.exe could not set WSL 2 as the default.' }
    }

    $direct = Invoke-WslInstallCommand -Distribution $distribution
    if ([bool](Get-ObjectValue -InputObject $direct -Name 'SecurityFailure' -Default $false)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = 'The system wsl.exe failed trusted path or signature validation during installation.' }
    }
    if ($direct.ExitCode -eq 0) {
        if (@(Get-WslDistributions | Where-Object { $_.Name -ieq $distribution -and $_.Version -eq 2 }).Count -gt 0) {
            return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'WSL 2 and the requested Ubuntu distribution were installed without launching it.' }
        }
        return [pscustomobject]@{ Success = $true; FailureKind = 'NeedsRestart'; Detail = 'WSL accepted the install request. Restart Windows manually and rerun to verify Ubuntu.' }
    }
    if (-not (Test-NetworkFailureEvidence -ExitCode $direct.ExitCode -Output $direct.Output)) {
        return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'wsl.exe failed without verified network-failure evidence; proxy retry was refused.' }
    }

    foreach ($candidate in (Get-ProxyCandidates -ExplicitProxyUri $ExplicitProxyUri)) {
        if (-not (Test-ProxyUri -ProxyUri $candidate)) {
            continue
        }
        $proxied = Invoke-WslInstallCommand -Distribution $distribution -ProxyUri $candidate
        if ([bool](Get-ObjectValue -InputObject $proxied -Name 'SecurityFailure' -Default $false)) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = 'The system wsl.exe failed trusted path or signature validation during proxied installation.' }
        }
        if ($proxied.ExitCode -eq 0) {
            if (@(Get-WslDistributions | Where-Object { $_.Name -ieq $distribution -and $_.Version -eq 2 }).Count -gt 0) {
                return [pscustomobject]@{ Success = $true; FailureKind = ''; Detail = 'Ubuntu was installed through a verified process-scoped proxy.' }
            }
            return [pscustomobject]@{ Success = $true; FailureKind = 'NeedsRestart'; Detail = 'WSL accepted the proxied install request. Restart Windows manually and rerun.' }
        }
        if (-not (Test-NetworkFailureEvidence -ExitCode $proxied.ExitCode -Output $proxied.Output)) {
            return [pscustomobject]@{ Success = $false; FailureKind = 'Failed'; Detail = 'The proxied wsl.exe install failed with a non-network error.' }
        }
    }
    return [pscustomobject]@{ Success = $false; FailureKind = 'NeedsProxy'; Detail = 'Ubuntu could not be downloaded directly and no verified proxy completed the request. Configure Clash and rerun.' }
}

function Get-ManualDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Prefix = ''
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        [void]$parts.Add($Prefix.Trim())
    }
    foreach ($action in (ConvertTo-StringArray (Get-ObjectValue -InputObject $Application -Name 'ManualActions' -Default @()))) {
        [void]$parts.Add($action)
    }
    return ($parts.ToArray() -join ' ')
}

function Install-CatalogApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Application,

        [Parameter(Mandatory = $true)]
        [object]$Catalog,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri,

        [Parameter()]
        [AllowNull()]
        [string]$SeedDirectory,

        [Parameter()]
        [switch]$NoGitHubMirrors
    )

    $safety = Get-ObjectValue -InputObject $Application -Name 'Safety' -Default @{}
    $ready = Get-ObjectValue -InputObject $safety -Name 'Ready' -Default $false
    if (-not [bool]$ready) {
        $failureStatus = [string](Get-ObjectValue -InputObject $safety -Name 'FailureStatus' -Default 'ManualActionRequired')
        if ($failureStatus -notin @('ManualActionRequired', 'NonCompliant', 'Failed')) {
            $failureStatus = 'ManualActionRequired'
        }
        $reason = [string](Get-ObjectValue -InputObject $safety -Name 'FailureReason' -Default 'The catalog entry is not approved for unattended installation.')
        return [pscustomobject]@{
            Status = $failureStatus
            Detail = Get-ManualDetail -Application $Application -Prefix $reason
        }
    }

    $installerType = [string](Get-ObjectValue -InputObject $Application -Name 'InstallerType')
    switch ($installerType) {
        'Winget' {
            $outcome = Invoke-WingetInstall -Application $Application -ExplicitProxyUri $ExplicitProxyUri
        }
        'Store' {
            $outcome = Invoke-WingetInstall -Application $Application -ExplicitProxyUri $ExplicitProxyUri
        }
        'Wsl' {
            $outcome = Install-WslApplication -Application $Application -ExplicitProxyUri $ExplicitProxyUri
        }
        'Direct' {
            $metadata = Get-DirectInstallerMetadata -Application $Application
            if ($null -eq $metadata) {
                return [pscustomobject]@{ Status = 'ManualActionRequired'; Detail = Get-ManualDetail -Application $Application -Prefix 'No reviewed direct installer metadata is cataloged.' }
            }
            $outcome = Install-DirectApplication -Application $Application -Metadata $metadata -SeedDirectory $SeedDirectory -ExplicitProxyUri $ExplicitProxyUri -NoGitHubMirrors:$NoGitHubMirrors -Catalog $Catalog
        }
        'ManualOrSeed' {
            $metadata = Get-DirectInstallerMetadata -Application $Application
            if ($null -eq $metadata) {
                return [pscustomobject]@{ Status = 'ManualActionRequired'; Detail = Get-ManualDetail -Application $Application -Prefix 'No reviewed seed metadata is cataloged.' }
            }
            $outcome = Install-DirectApplication -Application $Application -Metadata $metadata -SeedDirectory $SeedDirectory -ExplicitProxyUri $ExplicitProxyUri -NoGitHubMirrors:$NoGitHubMirrors -Catalog $Catalog
        }
        default {
            return [pscustomobject]@{ Status = 'Failed'; Detail = ("Unsupported installer type '$installerType'.") }
        }
    }

    if ($outcome.Success) {
        $successDetail = [string]$outcome.Detail
        $manualDetail = Get-ManualDetail -Application $Application
        if (-not [string]::IsNullOrWhiteSpace($manualDetail)) {
            $successDetail = ('{0} {1}' -f $successDetail.Trim(), $manualDetail.Trim()).Trim()
        }
        if ($outcome.FailureKind -eq 'NeedsRestart') {
            return [pscustomobject]@{ Status = 'NeedsRestart'; Detail = $successDetail }
        }
        return [pscustomobject]@{ Status = 'Installed'; Detail = $successDetail }
    }
    $failureKind = [string]$outcome.FailureKind
    if ($failureKind -notin @('NeedsProxy', 'NeedsRestart', 'ManualActionRequired', 'NonCompliant', 'Failed')) {
        $failureKind = 'Failed'
    }
    return [pscustomobject]@{ Status = $failureKind; Detail = $outcome.Detail }
}

function Install-ClashFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ClashResult,

        [Parameter(Mandatory = $true)]
        [object]$Catalog,

        [Parameter()]
        [AllowNull()]
        [string]$ExplicitProxyUri,

        [Parameter()]
        [AllowNull()]
        [string]$SeedDirectory,

        [Parameter()]
        [switch]$NoGitHubMirrors
    )

    $application = $ClashResult.Application
    $safety = Get-ObjectValue -InputObject $application -Name 'Safety' -Default @{}
    if (-not [bool](Get-ObjectValue -InputObject $safety -Name 'DirectFallbackReady' -Default $false)) {
        return $false
    }
    $metadata = Get-DirectInstallerMetadata -Application $application -PropertyName 'DirectFallbackInstaller'
    if ($null -eq $metadata) {
        return $false
    }
    $outcome = Install-DirectApplication -Application $application -Metadata $metadata -SeedDirectory $SeedDirectory -ExplicitProxyUri $ExplicitProxyUri -NoGitHubMirrors:$NoGitHubMirrors -Catalog $Catalog
    if (-not $outcome.Success) {
        $ClashResult.Status = $(if ($outcome.FailureKind -in $script:SupportedStatuses) { $outcome.FailureKind } else { 'Failed' })
        $ClashResult.Detail = $outcome.Detail
        return $false
    }
    $ClashResult.Status = 'Installed'
    $ClashResult.Detail = Get-ManualDetail -Application $application -Prefix 'Clash Verge Rev was installed from a verified fallback. Configure it and rerun.'
    return $true
}

function Show-BootstrapSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    Write-Host ''
    Write-Host ((Get-UiText -Key 'SummaryTitle' -Fallback 'Results') + ':') -ForegroundColor Cyan
    foreach ($result in @($Results | Sort-Object Order)) {
        $fileSummary = 'Result key={0}; status={1}' -f ([string]$result.Key), ([string]$result.Status)
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Detail)) {
            $fileSummary += '; detail={0}' -f ([string]$result.Detail)
        }
        Write-BootstrapLog -Message $fileSummary -Level Info -FileOnly
        $color = 'Gray'
        if ($result.Status -in @('Installed', 'AlreadyInstalled')) { $color = 'Green' }
        elseif ($result.Status -in @('NeedsProxy', 'NeedsRestart', 'ManualActionRequired', 'Skipped')) { $color = 'Yellow' }
        elseif ($result.Status -in @('NonCompliant', 'Failed')) { $color = 'Red' }
        Write-Host ('  [{0,-24}] {1}' -f (Get-StatusDisplayText -Status $result.Status), $result.Name) -ForegroundColor $color
        if ($result.Detail -and $result.Status -in @('NeedsProxy', 'NeedsRestart', 'ManualActionRequired', 'NonCompliant', 'Failed')) {
            Write-Host ('      {0}' -f (Protect-LogText -Text $result.Detail)) -ForegroundColor $color
        }
        elseif ($result.Status -eq 'Installed') {
            foreach ($action in (ConvertTo-StringArray (Get-ObjectValue -InputObject $result.Application -Name 'ManualActions' -Default @()))) {
                Write-Host ('      {0}' -f (Protect-LogText -Text $action)) -ForegroundColor Yellow
            }
        }
    }
    if (@($Results | Where-Object { $_.Status -in @('NeedsProxy', 'NeedsRestart', 'ManualActionRequired') }).Count -gt 0) {
        Write-Host (Get-UiText -Key 'RerunHint' -Fallback 'Complete the manual actions above, then rerun with the same arguments.') -ForegroundColor Yellow
    }
    if ($script:LogPath) {
        Write-Host ('{0}: {1}' -f (Get-UiText -Key 'LogPath' -Fallback 'Log path'), $script:LogPath) -ForegroundColor DarkGray
    }
}

function Invoke-Win11Bootstrap {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Config,

        [Parameter()]
        [ValidateNotNull()]
        [string[]]$Only,

        [Parameter()]
        [ValidateNotNull()]
        [string[]]$Skip,

        [Parameter()]
        [switch]$Yes,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProxyUri,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SeedDirectory,

        [Parameter()]
        [switch]$NoGitHubMirrors,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [switch]$ElevationAttempted
    )

    Initialize-UiStrings
    $effectiveDryRun = [bool]$DryRun -or [bool]$WhatIfPreference
    $script:DryRun = $effectiveDryRun

    $invocation = @{}
    foreach ($name in @('Config', 'Only', 'Skip', 'Yes', 'ProxyUri', 'SeedDirectory', 'NoGitHubMirrors')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $invocation[$name] = $PSBoundParameters[$name]
        }
    }

    try {
        Assert-SupportedEnvironment
        $catalog = Import-AppCatalog
        $options = Resolve-BootstrapOptions -Invocation $invocation -Catalog $catalog
    }
    catch [System.ArgumentException] {
        Write-Host ('Configuration error: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return 64
    }
    catch {
        Write-Host ('Preflight failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return 20
    }

    if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
        if ($ElevationAttempted) {
            Write-Host 'The elevated process does not have administrator rights; refusing to loop the UAC request.' -ForegroundColor Red
            return 20
        }
        # Resolve external JSON before UAC and pass only canonical, validated
        # options. The elevated process never reopens a user-writable config.
        $elevationInvocation = @{}
        if ($options.HasOnlySelection) {
            $elevationInvocation['Only'] = [string[]]@($options.OnlyKeys)
        }
        if ($options.ConfigPath -or $invocation.Contains('Skip') -or @($options.SkipKeys).Count -gt 0) {
            # An explicitly supplied config/skip suppresses the interactive menu
            # even when the effective skip set is empty.
            $elevationInvocation['Skip'] = [string[]]@($options.SkipKeys)
        }
        if ($invocation.Contains('Yes')) {
            $elevationInvocation['Yes'] = [bool]$options.Yes
        }
        if ($options.ProxyUri) {
            $elevationInvocation['ProxyUri'] = [string]$options.ProxyUri
        }
        if ($options.SeedDirectory) {
            $elevationInvocation['SeedDirectory'] = [string]$options.SeedDirectory
        }
        if ($invocation.Contains('NoGitHubMirrors') -or ($options.ConfigPath -and $options.NoGitHubMirrors)) {
            $elevationInvocation['NoGitHubMirrors'] = [bool]$options.NoGitHubMirrors
        }
        try {
            return Start-BootstrapElevated -ScriptPath $ScriptPath -Invocation $elevationInvocation
        }
        catch [System.Security.SecurityException] {
            Write-Host ('Secure elevation preflight rejected unsafe state: {0}' -f $_.Exception.Message) -ForegroundColor Red
            return 30
        }
        catch {
            Write-Host ('Administrator elevation failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            return 20
        }
    }

    try {
        Initialize-BootstrapLog -DryRun:$effectiveDryRun
    }
    catch [System.Security.SecurityException] {
        Write-Host ('Secure log initialization rejected unsafe state: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return 30
    }
    catch {
        Write-Host ('Unable to initialize the local log: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return 20
    }

    $applications = @(Get-ObjectValue -InputObject $catalog -Name 'Applications' | Sort-Object { [int](Get-ObjectValue -InputObject $_ -Name 'Order') })
    try {
        if ($options.ShowMenu) {
            $selectedApplications = @(Select-ApplicationsInteractive -Applications $applications)
        }
        elseif ($options.HasOnlySelection) {
            $selectedApplications = @($applications | Where-Object { $options.OnlyKeys -icontains [string](Get-ObjectValue -InputObject $_ -Name 'Key') })
        }
        else {
            $selectedApplications = @($applications)
        }
    }
    catch [System.ArgumentException] {
        Write-BootstrapLog -Message $_.Exception.Message -Level Error
        return 64
    }

    $results = New-Object System.Collections.Generic.List[object]
    $installSelection = New-Object System.Collections.Generic.List[object]
    foreach ($app in $selectedApplications) {
        $key = [string](Get-ObjectValue -InputObject $app -Name 'Key')
        if ($options.SkipKeys -icontains $key) {
            [void]$results.Add((New-BootstrapResult -Application $app -Status 'Skipped' -Detail 'Explicitly skipped by configuration.'))
        }
        else {
            [void]$installSelection.Add($app)
        }
    }

    $uninstallEntries = @(Get-UninstallEntries)
    foreach ($app in $installSelection.ToArray()) {
        $detection = Test-AppInstalled -Application $app -UninstallEntries $uninstallEntries -DryRun:$effectiveDryRun
        if ($detection.NonCompliant) {
            [void]$results.Add((New-BootstrapResult -Application $app -Status 'NonCompliant' -Detail $detection.Detail -Version $detection.Version))
        }
        elseif ($detection.Installed) {
            [void]$results.Add((New-BootstrapResult -Application $app -Status 'AlreadyInstalled' -Detail $detection.Detail -Version $detection.Version))
        }
        else {
            $safety = Get-ObjectValue -InputObject $app -Name 'Safety' -Default @{}
            if (-not [bool](Get-ObjectValue -InputObject $safety -Name 'Ready' -Default $false)) {
                $status = [string](Get-ObjectValue -InputObject $safety -Name 'FailureStatus' -Default 'ManualActionRequired')
                if ($status -notin @('ManualActionRequired', 'NonCompliant', 'Failed')) { $status = 'ManualActionRequired' }
                $detail = Get-ManualDetail -Application $app -Prefix ([string](Get-ObjectValue -InputObject $safety -Name 'FailureReason' -Default 'This installer is not approved for unattended execution.'))
                [void]$results.Add((New-BootstrapResult -Application $app -Status $status -Detail $detail))
            }
            else {
                [void]$results.Add((New-BootstrapResult -Application $app -Status 'Planned'))
            }
        }
    }

    Show-BootstrapPlan -Results $results.ToArray()
    if ($effectiveDryRun) {
        $directAvailable = Test-DirectHttps
        if ($directAvailable) {
            Write-BootstrapLog -Message 'Network probe: direct HTTPS is available.' -Level Debug
        }
        else {
            $verifiedProxy = $null
            foreach ($candidate in (Get-ProxyCandidates -ExplicitProxyUri $options.ProxyUri)) {
                if (Test-ProxyUri -ProxyUri $candidate) {
                    $verifiedProxy = $candidate
                    break
                }
            }
            if ($verifiedProxy) {
                Write-BootstrapLog -Message ('Network probe: direct HTTPS failed; verified proxy {0} is available.' -f (Get-SafeProxyLabel -ProxyUri $verifiedProxy)) -Level Warning
            }
            else {
                Write-BootstrapLog -Message 'Network probe: neither direct HTTPS nor an allowed proxy candidate is currently available.' -Level Warning
            }
        }
        Write-BootstrapLog -Message (Get-UiText -Key 'DryRunNotice' -Fallback 'WhatIf mode: no system changes will be made.') -Level Warning
        Show-BootstrapSummary -Results $results.ToArray()
        return Get-ExitCodeForResults -Results $results.ToArray()
    }

    if (@($results | Where-Object { $_.Status -eq 'Planned' }).Count -eq 0) {
        Show-BootstrapSummary -Results $results.ToArray()
        return Get-ExitCodeForResults -Results $results.ToArray()
    }

    try {
        if (-not (Confirm-BootstrapPlan -Yes:$options.Yes)) {
            Write-BootstrapLog -Message 'Cancelled before installation; no planned changes were made.' -Level Warning
            return Get-ExitCodeForResults -Results $results.ToArray()
        }
    }
    catch [System.ArgumentException] {
        Write-BootstrapLog -Message $_.Exception.Message -Level Error
        return 64
    }

    $wingetPlanned = @($results | Where-Object {
        $_.Status -eq 'Planned' -and ([string](Get-ObjectValue -InputObject $_.Application -Name 'InstallerType')) -in @('Winget', 'Store')
    })
    if ($wingetPlanned.Count -gt 0) {
        $wingetState = Repair-WinGetAvailability -ExplicitProxyUri $options.ProxyUri
        if (-not $wingetState.Success) {
            $clashResult = $results | Where-Object { $_.Key -eq 'clash-verge-rev' -and $_.Status -eq 'Planned' } | Select-Object -First 1
            $fallbackInstalled = $false
            if ($null -ne $clashResult -and $wingetState.FailureKind -ne 'NonCompliant') {
                $fallbackInstalled = Install-ClashFallback -ClashResult $clashResult -Catalog $catalog -ExplicitProxyUri $options.ProxyUri -SeedDirectory $options.SeedDirectory -NoGitHubMirrors:$options.NoGitHubMirrors
            }
            foreach ($result in @($results | Where-Object { $_.Status -eq 'Planned' })) {
                if ($fallbackInstalled) {
                    $result.Status = 'NeedsProxy'
                    $result.Detail = 'Configure the newly installed Clash Verge Rev proxy and rerun.'
                }
                else {
                    $result.Status = $(if ($wingetState.FailureKind -in @('NeedsProxy', 'NonCompliant')) { $wingetState.FailureKind } else { 'Failed' })
                    $result.Detail = $wingetState.Detail
                }
            }
            Show-BootstrapSummary -Results $results.ToArray()
            return Get-ExitCodeForResults -Results $results.ToArray()
        }
    }

    foreach ($result in @($results | Where-Object { $_.Status -eq 'Planned' } | Sort-Object InstallOrder)) {
        $installResult = Install-CatalogApplication -Application $result.Application -Catalog $catalog -ExplicitProxyUri $options.ProxyUri -SeedDirectory $options.SeedDirectory -NoGitHubMirrors:$options.NoGitHubMirrors
        $result.Status = $installResult.Status
        $result.Detail = $installResult.Detail
        if ($result.Status -eq 'Installed') {
            Write-BootstrapLog -Message ('Installed: {0}' -f $result.Name) -Level Success
        }
        elseif ($result.Status -in @('NeedsProxy', 'NeedsRestart', 'ManualActionRequired')) {
            Write-BootstrapLog -Message ('{0}: {1}' -f $result.Name, $result.Detail) -Level Warning
        }
        else {
            Write-BootstrapLog -Message ('{0}: {1}' -f $result.Name, $result.Detail) -Level Error
        }
    }

    Show-BootstrapSummary -Results $results.ToArray()
    return Get-ExitCodeForResults -Results $results.ToArray()
}

Export-ModuleMember -Function @(
    'Invoke-Win11Bootstrap',
    'Get-BootstrapElevationPayload',
    'ConvertFrom-SelectionExpression',
    'Resolve-BootstrapOptions',
    'Get-ExitCodeForResults',
    'Import-AppCatalog',
    'Protect-LogText',
    'Test-InstallerTrust'
)
