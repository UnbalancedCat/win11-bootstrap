#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-AcceptanceSha256 {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Text')][string]$Text,
        [Parameter(Mandatory = $true, ParameterSetName = 'File')][string]$LiteralPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($utf8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Protect-AcceptanceText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][AllowEmptyString()][string]$Text)

    process {
        $redacted = $Text
        $redacted = [regex]::Replace($redacted, '(?i)\b(authorization\s*:\s*)(?:bearer\s+)?[^\s,;]+', '$1[REDACTED]')
        $redacted = [regex]::Replace($redacted, '(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1[REDACTED]')
        $redacted = [regex]::Replace($redacted, '(?i)([?&](?:token|access_token|key|secret|password|passwd|pwd|subscription|url)=)[^&#\s]+', '$1[REDACTED]')
        $redacted = [regex]::Replace($redacted, '(?i)\b((?:https?|socks5?)://)[^/@\s]+@', '$1[REDACTED]@')
        $redacted = [regex]::Replace($redacted, '(?i)\b(C:\\Users\\)[^\\\s]+', '$1[USER]')
        return $redacted
    }
}

function Test-AcceptanceSecretText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $patterns = @(
        '(?i)authorization\s*:\s*(?:bearer\s+)?(?!\[REDACTED\])\S+',
        '(?i)\b(?:https?|socks5?)://(?!\[REDACTED\]@)[^/@\s]+@',
        '(?i)[?&](?:token|access_token|key|secret|password|passwd|pwd|subscription|url)=(?!\[REDACTED\])[^&#\s]+',
        '(?i)\b(?:token|secret|password|subscription)\s*[:=]\s*(?!\[REDACTED\]|null\b|false\b|true\b)[^\s,}]{6,}'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { return $false }
    }
    return $true
}

function Get-AcceptanceObjectValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-AcceptanceObjectMember {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-AcceptanceInterfaceIndex {
    param([Parameter(Mandatory = $true)]$InputObject)

    $value = Get-AcceptanceObjectValue -InputObject $InputObject -Name 'InterfaceIndex'
    if ($null -eq $value) {
        $value = Get-AcceptanceObjectValue -InputObject $InputObject -Name 'ifIndex' -Default 0
    }
    return [int]$value
}

function ConvertTo-AcceptanceNetworkState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$NetworkState)

    $adapters = @(
        foreach ($adapter in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'adapters' -Default @())) {
            if ($null -eq $adapter) { continue }
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $adapter
                Name = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $adapter -Name 'Name' -Default ''))
                InterfaceDescription = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $adapter -Name 'InterfaceDescription' -Default ''))
                Status = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $adapter -Name 'Status' -Default ''))
                MacAddress = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $adapter -Name 'MacAddress' -Default ''))
            }
        }
    )
    $adapters = @($adapters | Sort-Object -Property InterfaceIndex, Name, InterfaceDescription, Status, MacAddress)

    $ipv4Addresses = @(
        foreach ($address in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv4Addresses' -Default @())) {
            if ($null -eq $address) { continue }
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $address
                IPAddress = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $address -Name 'IPAddress' -Default ''))
                PrefixLength = [int](Get-AcceptanceObjectValue -InputObject $address -Name 'PrefixLength' -Default 0)
            }
        }
    )
    $ipv4Addresses = @($ipv4Addresses | Sort-Object -Property InterfaceIndex, IPAddress, PrefixLength)

    $ipv4Routes = @(
        foreach ($route in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv4Routes' -Default @())) {
            if ($null -eq $route) { continue }
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $route
                DestinationPrefix = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $route -Name 'DestinationPrefix' -Default ''))
                NextHop = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $route -Name 'NextHop' -Default ''))
                RouteMetric = [int](Get-AcceptanceObjectValue -InputObject $route -Name 'RouteMetric' -Default 0)
            }
        }
    )
    $ipv4Routes = @($ipv4Routes | Sort-Object -Property InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)

    $ipv4Dns = @(
        foreach ($dns in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv4Dns' -Default @())) {
            if ($null -eq $dns) { continue }
            $serverAddresses = @(
                foreach ($serverAddress in @(Get-AcceptanceObjectValue -InputObject $dns -Name 'ServerAddresses' -Default @())) {
                    if ($null -ne $serverAddress) {
                        Protect-AcceptanceText -Text ([string]$serverAddress)
                    }
                }
            )
            $serverAddresses = @($serverAddresses | Sort-Object -Unique)
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $dns
                ServerAddresses = $serverAddresses
            }
        }
    )
    $ipv4Dns = @($ipv4Dns | Sort-Object -Property InterfaceIndex, @{ Expression = { @($_.ServerAddresses) -join ',' } })

    $ipv6Addresses = @(
        foreach ($address in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv6Addresses' -Default @())) {
            if ($null -eq $address) { continue }
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $address
                IPAddress = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $address -Name 'IPAddress' -Default ''))
                PrefixLength = [int](Get-AcceptanceObjectValue -InputObject $address -Name 'PrefixLength' -Default 0)
            }
        }
    )
    $ipv6Addresses = @($ipv6Addresses | Sort-Object -Property InterfaceIndex, IPAddress, PrefixLength)

    $ipv6Routes = @(
        foreach ($route in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv6Routes' -Default @())) {
            if ($null -eq $route) { continue }
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $route
                DestinationPrefix = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $route -Name 'DestinationPrefix' -Default ''))
                NextHop = Protect-AcceptanceText -Text ([string](Get-AcceptanceObjectValue -InputObject $route -Name 'NextHop' -Default ''))
                RouteMetric = [int](Get-AcceptanceObjectValue -InputObject $route -Name 'RouteMetric' -Default 0)
            }
        }
    )
    $ipv6Routes = @($ipv6Routes | Sort-Object -Property InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)

    $ipv6Dns = @(
        foreach ($dns in @(Get-AcceptanceObjectValue -InputObject $NetworkState -Name 'ipv6Dns' -Default @())) {
            if ($null -eq $dns) { continue }
            $serverAddresses = @(
                foreach ($serverAddress in @(Get-AcceptanceObjectValue -InputObject $dns -Name 'ServerAddresses' -Default @())) {
                    if ($null -ne $serverAddress) {
                        Protect-AcceptanceText -Text ([string]$serverAddress)
                    }
                }
            )
            $serverAddresses = @($serverAddresses | Sort-Object -Unique)
            [pscustomobject][ordered]@{
                InterfaceIndex = Get-AcceptanceInterfaceIndex -InputObject $dns
                ServerAddresses = $serverAddresses
            }
        }
    )
    $ipv6Dns = @($ipv6Dns | Sort-Object -Property InterfaceIndex, @{ Expression = { @($_.ServerAddresses) -join ',' } })

    return [ordered]@{
        adapters = $adapters
        ipv4Addresses = $ipv4Addresses
        ipv4Routes = $ipv4Routes
        ipv4Dns = $ipv4Dns
        ipv6Addresses = $ipv6Addresses
        ipv6Routes = $ipv6Routes
        ipv6Dns = $ipv6Dns
    }
}

function ConvertTo-AcceptanceJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$InputObject)

    return (($InputObject | ConvertTo-Json -Depth 16 -Compress) + "`n")
}

function Invoke-AcceptanceCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @())

    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        return [ordered]@{ exitCode = $LASTEXITCODE; output = (Protect-AcceptanceText -Text $output.Trim()) }
    }
    catch {
        return [ordered]@{ exitCode = -1; output = (Protect-AcceptanceText -Text $_.Exception.Message) }
    }
}

function Get-AcceptanceSystemState {
    [CmdletBinding()]
    param()

    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $winInet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $proxyEnable = $null
    $proxyServer = $null
    $autoConfigUrl = $null
    if ($null -ne $winInet) {
        if ($null -ne $winInet.PSObject.Properties['ProxyEnable']) { $proxyEnable = $winInet.ProxyEnable }
        if ($null -ne $winInet.PSObject.Properties['ProxyServer']) { $proxyServer = Protect-AcceptanceText -Text ([string]$winInet.ProxyServer) }
        if ($null -ne $winInet.PSObject.Properties['AutoConfigURL']) { $autoConfigUrl = Protect-AcceptanceText -Text ([string]$winInet.AutoConfigURL) }
    }
    $proxyEnvironment = [ordered]@{}
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $values = [ordered]@{}
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            $values[$name] = if ($null -eq $value) { $null } else { Protect-AcceptanceText -Text $value }
        }
        $proxyEnvironment[$scope.ToLowerInvariant()] = $values
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $wingetState = [ordered]@{ available = ($null -ne $winget); path = $null; version = $null; features = $null }
    if ($winget) {
        $wingetState.path = Protect-AcceptanceText -Text $winget.Source
        $wingetState.version = Invoke-AcceptanceCommand -FilePath $winget.Source -Arguments @('--version')
        $wingetState.features = Invoke-AcceptanceCommand -FilePath $winget.Source -Arguments @('features')
    }

    $firewallProfiles = @()
    if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        $firewallProfiles = @(Get-NetFirewallProfile -ErrorAction Stop | Sort-Object Name | ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                enabled = [bool]$_.Enabled
                defaultInboundAction = [string]$_.DefaultInboundAction
                defaultOutboundAction = [string]$_.DefaultOutboundAction
            }
        })
    }

    $networkState = [ordered]@{
        adapters = @()
        ipv4Addresses = @()
        ipv4Routes = @()
        ipv4Dns = @()
        ipv6Addresses = @()
        ipv6Routes = @()
        ipv6Dns = @()
    }
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        $networkState.adapters = @(Get-NetAdapter -ErrorAction Stop)
    }
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        $networkState.ipv4Addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
    }
    if (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) {
        $networkState.ipv4Routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    }
    if (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
        $networkState.ipv4Dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop)
        $networkState.ipv6Dns = @(Get-DnsClientServerAddress -AddressFamily IPv6 -ErrorAction Stop)
    }
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        $networkState.ipv6Addresses = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop)
    }
    if (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) {
        $networkState.ipv6Routes = @(Get-NetRoute -AddressFamily IPv6 -ErrorAction Stop)
    }

    return [ordered]@{
        schemaVersion = 2
        os = [ordered]@{
            productName = [string]$os.ProductName
            displayVersion = [string]$os.DisplayVersion
            currentBuild = [string]$os.CurrentBuild
            ubr = [int]$os.UBR
        }
        proxy = [ordered]@{
            environment = $proxyEnvironment
            winInet = [ordered]@{
                proxyEnable = $proxyEnable
                proxyServer = $proxyServer
                autoConfigUrl = $autoConfigUrl
            }
            winHttp = Invoke-AcceptanceCommand -FilePath 'netsh.exe' -Arguments @('winhttp', 'show', 'proxy')
        }
        winget = $wingetState
        firewallProfiles = $firewallProfiles
        network = ConvertTo-AcceptanceNetworkState -NetworkState $networkState
    }
}

function Assert-AcceptanceSystemStateContract {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'before'; State = $Before },
        [pscustomobject]@{ Name = 'after'; State = $After }
    )) {
        if (-not (Test-AcceptanceObjectMember -InputObject $entry.State -Name 'schemaVersion')) {
            throw "System state '$($entry.Name)' is missing required field 'schemaVersion'."
        }
        $schemaVersion = Get-AcceptanceObjectValue -InputObject $entry.State -Name 'schemaVersion'
        if ($schemaVersion -isnot [int]) {
            throw "System state '$($entry.Name)' schemaVersion must be integer 2."
        }
    }

    $beforeSchemaVersion = Get-AcceptanceObjectValue -InputObject $Before -Name 'schemaVersion'
    $afterSchemaVersion = Get-AcceptanceObjectValue -InputObject $After -Name 'schemaVersion'
    if ($beforeSchemaVersion -ne $afterSchemaVersion) {
        throw 'System-state schemaVersion mismatch between before and after.'
    }
    if ($beforeSchemaVersion -ne 2) {
        throw "Unsupported system-state schemaVersion '$beforeSchemaVersion'; expected 2."
    }

    $requiredTopLevelFields = @('os', 'proxy', 'winget', 'firewallProfiles', 'network')
    $requiredNetworkFields = @(
        'adapters', 'ipv4Addresses', 'ipv4Routes', 'ipv4Dns',
        'ipv6Addresses', 'ipv6Routes', 'ipv6Dns'
    )
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'before'; State = $Before },
        [pscustomobject]@{ Name = 'after'; State = $After }
    )) {
        foreach ($field in $requiredTopLevelFields) {
            if (-not (Test-AcceptanceObjectMember -InputObject $entry.State -Name $field)) {
                throw "System state '$($entry.Name)' is missing required field '$field'."
            }
        }
        $network = Get-AcceptanceObjectValue -InputObject $entry.State -Name 'network'
        foreach ($field in $requiredNetworkFields) {
            if (-not (Test-AcceptanceObjectMember -InputObject $network -Name $field)) {
                throw "System state '$($entry.Name).network' is missing required field '$field'."
            }
        }
    }
}

function Compare-AcceptanceSystemState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Before, [Parameter(Mandatory = $true)]$After)

    Assert-AcceptanceSystemStateContract -Before $Before -After $After
    $beforeJson = ConvertTo-AcceptanceJson -InputObject $Before
    $afterJson = ConvertTo-AcceptanceJson -InputObject $After
    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($propertyName in @('schemaVersion', 'os', 'proxy', 'winget', 'firewallProfiles', 'network')) {
        $beforeValue = ConvertTo-AcceptanceJson -InputObject $Before.$propertyName
        $afterValue = ConvertTo-AcceptanceJson -InputObject $After.$propertyName
        if ($beforeValue -cne $afterValue) { [void]$differences.Add($propertyName) }
    }
    return [ordered]@{
        equal = ($beforeJson -ceq $afterJson)
        beforeSha256 = Get-AcceptanceSha256 -Text $beforeJson
        afterSha256 = Get-AcceptanceSha256 -Text $afterJson
        differences = $differences.ToArray()
    }
}

function Compare-AcceptanceStatuses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Expected,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Actual
    )

    $allowedStatuses = @('Planned', 'AlreadyInstalled', 'Installed', 'Skipped', 'NeedsProxy', 'NeedsRestart', 'ManualActionRequired', 'NonCompliant', 'Failed')
    $keys = @($Expected.Keys + $Actual.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $differences = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $keys) {
        $expectedStatus = if ($Expected.Contains($key)) { [string]$Expected[$key] } else { $null }
        $actualStatus = if ($Actual.Contains($key)) { [string]$Actual[$key] } else { $null }
        if (($expectedStatus -and $expectedStatus -notin $allowedStatuses) -or ($actualStatus -and $actualStatus -notin $allowedStatuses)) {
            throw "Unknown stable status for '$key'."
        }
        if ($expectedStatus -cne $actualStatus) {
            [void]$differences.Add([ordered]@{ key = $key; expected = $expectedStatus; actual = $actualStatus })
        }
    }
    return [ordered]@{ equal = ($differences.Count -eq 0); differences = $differences.ToArray() }
}

function New-AcceptanceEvidenceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^VM-0(?:0[1-9]|10|11)$')][string]$ScenarioId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$RuntimeFingerprint,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ToolkitCommit,
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$Checkpoint,
        [Parameter(Mandatory = $true)][string]$OsBuild,
        [Parameter(Mandatory = $true)][string]$WinGetVersion,
        [Parameter(Mandatory = $true)][datetime]$StartedAtUtc,
        [Parameter(Mandatory = $true)][datetime]$EndedAtUtc,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$CommandSha256,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][hashtable]$Statuses,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$BeforeStateSha256,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$AfterStateSha256,
        [Parameter()][object[]]$Files = @(),
        [Parameter()][object[]]$Events = @()
    )

    if ($EndedAtUtc.ToUniversalTime() -lt $StartedAtUtc.ToUniversalTime()) { throw 'Evidence end time precedes its start time.' }
    $manifest = [ordered]@{
        schemaVersion = 1; scenarioId = $ScenarioId; candidateCommit = $CandidateCommit
        runtimeFingerprint = $RuntimeFingerprint; archiveSha256 = $ArchiveSha256; toolkitCommit = $ToolkitCommit
        vmId = Protect-AcceptanceText -Text $VmId; checkpoint = Protect-AcceptanceText -Text $Checkpoint
        osBuild = $OsBuild; winGetVersion = $WinGetVersion
        startedAtUtc = $StartedAtUtc.ToUniversalTime().ToString('o'); endedAtUtc = $EndedAtUtc.ToUniversalTime().ToString('o')
        commandSha256 = $CommandSha256; exitCode = $ExitCode; statuses = $Statuses
        beforeStateSha256 = $BeforeStateSha256; afterStateSha256 = $AfterStateSha256
        files = @($Files); events = @($Events)
    }
    $json = ConvertTo-AcceptanceJson -InputObject $manifest
    if (-not (Test-AcceptanceSecretText -Text $json)) { throw 'Evidence manifest contains a possible secret.' }
    return $manifest
}

function Test-AcceptanceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Manifest)

    $json = ConvertTo-AcceptanceJson -InputObject $Manifest
    $required = @('schemaVersion', 'scenarioId', 'candidateCommit', 'runtimeFingerprint', 'archiveSha256', 'toolkitCommit', 'vmId', 'checkpoint', 'osBuild', 'winGetVersion', 'startedAtUtc', 'endedAtUtc', 'commandSha256', 'exitCode', 'statuses', 'beforeStateSha256', 'afterStateSha256', 'files', 'events')
    $propertyNames = if ($Manifest -is [Collections.IDictionary]) { @($Manifest.Keys) } else { @($Manifest.PSObject.Properties.Name) }
    $missing = @($required | Where-Object {
        if ($Manifest -is [Collections.IDictionary]) { -not $Manifest.Contains($_) }
        else { $null -eq $Manifest.PSObject.Properties[$_] }
    })
    $unexpected = @($propertyNames | Where-Object { $_ -notin $required })
    $formatValid = $missing.Count -eq 0
    if ($formatValid) {
        $formatValid = (
            [int]$Manifest.schemaVersion -eq 1 -and
            [string]$Manifest.scenarioId -match '^VM-0(?:0[1-9]|10|11)$' -and
            [string]$Manifest.candidateCommit -cmatch '^[0-9a-f]{40}$' -and
            [string]$Manifest.runtimeFingerprint -cmatch '^sha256:[0-9a-f]{64}$' -and
            [string]$Manifest.archiveSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$Manifest.toolkitCommit -cmatch '^[0-9a-f]{40}$' -and
            [string]$Manifest.commandSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$Manifest.beforeStateSha256 -cmatch '^[0-9a-f]{64}$' -and
            [string]$Manifest.afterStateSha256 -cmatch '^[0-9a-f]{64}$' -and
            [int]$Manifest.exitCode -in @(0, 10, 20, 30, 64)
        )
    }
    return [ordered]@{
        valid = ($formatValid -and $unexpected.Count -eq 0 -and (Test-AcceptanceSecretText -Text $json))
        missing = $missing
        unexpected = $unexpected
    }
}

Export-ModuleMember -Function @(
    'Get-AcceptanceSha256', 'Protect-AcceptanceText', 'Test-AcceptanceSecretText',
    'ConvertTo-AcceptanceJson', 'ConvertTo-AcceptanceNetworkState', 'Get-AcceptanceSystemState', 'Compare-AcceptanceSystemState',
    'Compare-AcceptanceStatuses', 'New-AcceptanceEvidenceManifest', 'Test-AcceptanceEvidence'
)
