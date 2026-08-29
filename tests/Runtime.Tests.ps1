#requires -Version 5.1

function Assert-RuntimeEqual {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Actual,

        [Parameter()]
        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
        $actualText = @($Actual) -join '|'
        $expectedText = @($Expected) -join '|'
        if ($actualText -cne $expectedText) {
            throw "$Label expected [$expectedText], found [$actualText]."
        }
        return
    }
    if ($null -eq $Actual -and $null -eq $Expected) {
        return
    }
    if ($null -eq $Actual -or $null -eq $Expected -or $Actual -cne $Expected) {
        throw "$Label expected [$Expected], found [$Actual]."
    }
}

function Assert-RuntimeThrows {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "$Label expected an exception."
    }
}

Describe 'Bootstrap runtime contract' {
    BeforeAll {
        function Assert-RuntimeEqual {
            param(
                [Parameter()]
                [AllowNull()]
                [object]$Actual,
                [Parameter()]
                [AllowNull()]
                [object]$Expected,
                [Parameter(Mandatory = $true)]
                [string]$Label
            )
            if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
                $actualText = @($Actual) -join '|'
                $expectedText = @($Expected) -join '|'
                if ($actualText -cne $expectedText) { throw "$Label expected [$expectedText], found [$actualText]." }
                return
            }
            if ($null -eq $Actual -and $null -eq $Expected) { return }
            if ($null -eq $Actual -or $null -eq $Expected -or $Actual -cne $Expected) {
                throw "$Label expected [$Expected], found [$Actual]."
            }
        }
        function Assert-RuntimeThrows {
            param(
                [Parameter(Mandatory = $true)]
                [scriptblock]$Action,
                [Parameter(Mandatory = $true)]
                [string]$Label
            )
            $threw = $false
            try { & $Action } catch { $threw = $true }
            if (-not $threw) { throw "$Label expected an exception." }
        }
        $script:InvokeBootstrapChildProcess = {
            param(
                [Parameter(Mandatory = $true)]
                [string]$BootstrapPath,

                [Parameter(Mandatory = $true)]
                [string]$ArgumentText
            )

            # GitHub Actions sets ErrorActionPreference to Stop. Invoke the
            # entry point through System.Diagnostics.Process so expected child
            # stderr remains test data instead of becoming a parent error.
            if ($BootstrapPath.Contains('"')) {
                throw 'The bootstrap test path contains an unsupported quote character.'
            }
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
            $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $BootstrapPath + '" ' + $ArgumentText
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            try {
                if (-not $process.Start()) {
                    throw 'The bootstrap child process could not be started.'
                }
                $standardOutput = $process.StandardOutput.ReadToEnd()
                $standardError = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                return [pscustomobject]@{
                    ExitCode = [int]$process.ExitCode
                    StandardOutput = $standardOutput
                    StandardError = $standardError
                }
            }
            finally {
                $process.Dispose()
            }
        }
        $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:ModulePath = Join-Path $script:RepositoryRoot 'src\Win11Bootstrap.psm1'
        Import-Module -Name $script:ModulePath -Force
        $script:Catalog = Import-AppCatalog
    }

    It 'loads the reviewed 17-item catalog through the runtime' {
        Assert-RuntimeEqual -Actual @($script:Catalog.Applications).Count -Expected 17 -Label 'Catalog count'
    }

    It 'parses default, all, none, ranges, and duplicate selections' {
        Assert-RuntimeEqual -Actual @(ConvertFrom-SelectionExpression -Expression '' -Maximum 4) -Expected @(1, 2, 3, 4) -Label 'Default selection'
        Assert-RuntimeEqual -Actual @(ConvertFrom-SelectionExpression -Expression 'all' -Maximum 3) -Expected @(1, 2, 3) -Label 'All selection'
        Assert-RuntimeEqual -Actual @(ConvertFrom-SelectionExpression -Expression 'none' -Maximum 3).Count -Expected 0 -Label 'None selection count'
        Assert-RuntimeEqual -Actual @(ConvertFrom-SelectionExpression -Expression '1,3-5,3' -Maximum 5) -Expected @(1, 3, 4, 5) -Label 'Range selection'
    }

    It 'rejects malformed or out-of-range menu selections' {
        Assert-RuntimeThrows -Action { ConvertFrom-SelectionExpression -Expression '0,2' -Maximum 3 } -Label 'Zero selection'
        Assert-RuntimeThrows -Action { ConvertFrom-SelectionExpression -Expression '3-2' -Maximum 3 } -Label 'Reverse range'
        Assert-RuntimeThrows -Action { ConvertFrom-SelectionExpression -Expression 'one' -Maximum 3 } -Label 'Text selection'
    }

    It 'applies CLI only replacement and skip union over JSON config' {
        $configPath = Join-Path $TestDrive 'options.json'
        @'
{
  "only": ["chrome", "git"],
  "skip": ["chrome"],
  "proxyUri": "http://127.0.0.1:7890",
  "noGitHubMirrors": false
}
'@ | Set-Content -LiteralPath $configPath -Encoding ascii

        $options = Resolve-BootstrapOptions -Invocation @{
            Config = $configPath
            Only = @('git', 'vscode')
            Skip = @('vscode')
            ProxyUri = 'http://127.0.0.1:7897'
            NoGitHubMirrors = $true
            Yes = $true
        } -Catalog $script:Catalog

        Assert-RuntimeEqual -Actual @($options.OnlyKeys) -Expected @('git', 'vscode') -Label 'CLI only keys'
        Assert-RuntimeEqual -Actual @($options.SkipKeys) -Expected @('chrome', 'vscode') -Label 'Skip union'
        Assert-RuntimeEqual -Actual $options.ProxyUri -Expected 'http://127.0.0.1:7897/' -Label 'Proxy precedence'
        Assert-RuntimeEqual -Actual $options.NoGitHubMirrors -Expected $true -Label 'Mirror precedence'
        Assert-RuntimeEqual -Actual $options.Yes -Expected $true -Label 'Yes option'
        Assert-RuntimeEqual -Actual $options.ShowMenu -Expected $false -Label 'Automated menu state'
    }

    It 'rejects unknown config properties and application keys' {
        $badConfigPath = Join-Path $TestDrive 'bad-options.json'
        '{"only":["git"],"yes":true}' | Set-Content -LiteralPath $badConfigPath -Encoding ascii
        Assert-RuntimeThrows -Action { Resolve-BootstrapOptions -Invocation @{ Config = $badConfigPath } -Catalog $script:Catalog } -Label 'Unknown config property'
        Assert-RuntimeThrows -Action { Resolve-BootstrapOptions -Invocation @{ Only = @('not-an-app') } -Catalog $script:Catalog } -Label 'Unknown application key'
    }

    It 'uses stable highest-severity exit codes' {
        Assert-RuntimeEqual -Actual (Get-ExitCodeForResults -Results @()) -Expected 0 -Label 'Empty result code'
        Assert-RuntimeEqual -Actual (Get-ExitCodeForResults -Results @([pscustomobject]@{ Status = 'NeedsProxy' })) -Expected 10 -Label 'Recoverable result code'
        Assert-RuntimeEqual -Actual (Get-ExitCodeForResults -Results @([pscustomobject]@{ Status = 'NeedsRestart' }, [pscustomobject]@{ Status = 'Failed' })) -Expected 20 -Label 'Failure result code'
        Assert-RuntimeEqual -Actual (Get-ExitCodeForResults -Results @([pscustomobject]@{ Status = 'Failed' }, [pscustomobject]@{ Status = 'NonCompliant' })) -Expected 30 -Label 'Policy result code'
    }

    It 'redacts proxy credentials, bearer values, and secret query values' {
        $safe = Protect-LogText -Text 'http://alice:p%40ss@127.0.0.1:7897/?token=abc Bearer abc.def-123'
        if ($safe -match 'alice|p%40ss|token=abc|abc\.def-123') {
            throw "Protected log text still contains a secret: $safe"
        }
        if ($safe -notmatch '\*\*\*') {
            throw 'Protected log text did not contain a redaction marker.'
        }
    }

    It 'fails installer trust closed when metadata or file is missing' {
        $missing = Test-InstallerTrust -Path (Join-Path $TestDrive 'missing.exe') -ExpectedSha256 ('0' * 64) -ExpectedSignerSubject 'Example'
        Assert-RuntimeEqual -Actual $missing.Trusted -Expected $false -Label 'Missing installer trust'

        $file = Join-Path $TestDrive 'unsigned.exe'
        'not an executable' | Set-Content -LiteralPath $file -Encoding ascii
        $invalidHash = Test-InstallerTrust -Path $file -ExpectedSha256 'placeholder' -ExpectedSignerSubject 'Example'
        Assert-RuntimeEqual -Actual $invalidHash.Trusted -Expected $false -Label 'Invalid metadata trust'
    }

    It 'requires an exact case-insensitive Authenticode subject match' {
        $file = Join-Path $TestDrive 'signed-placeholder.exe'
        'placeholder' | Set-Content -LiteralPath $file -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_SIGNED_FILE', $file, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Get-FileHash { [pscustomobject]@{ Hash = ('A' * 64) } }
                Mock Get-AuthenticodeSignature {
                    [pscustomobject]@{
                        Status = 'Valid'
                        SignerCertificate = [pscustomobject]@{ Subject = 'CN=Trusted Publisher, O=Example' }
                    }
                }
                $path = [Environment]::GetEnvironmentVariable('WIN11_TEST_SIGNED_FILE', 'Process')
                $partial = Test-InstallerTrust -Path $path -ExpectedSha256 ('A' * 64) -ExpectedSignerSubject 'CN=Trusted Publisher'
                $exact = Test-InstallerTrust -Path $path -ExpectedSha256 ('A' * 64) -ExpectedSignerSubject 'cn=trusted publisher, o=example'
                if ($partial.Trusted -or -not $exact.Trusted) {
                    throw 'Authenticode signer subject comparison was not exact and case-insensitive.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_SIGNED_FILE', $null, 'Process')
        }
    }

    It 'consumes the elevation payload exactly once and clears process state' {
        $id = [Guid]::NewGuid().ToString('N')
        $environmentName = 'WIN11_BOOTSTRAP_ELEVATION_{0}' -f $id.ToUpperInvariant()
        $json = ConvertTo-Json -InputObject @{ Only = @('git'); ProxyUri = 'http://127.0.0.1:7897' } -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        [Environment]::SetEnvironmentVariable($environmentName, $encoded, 'Process')
        try {
            $payload = Get-BootstrapElevationPayload -Id $id
            Assert-RuntimeEqual -Actual @($payload.Only) -Expected @('git') -Label 'Elevation only payload'
            Assert-RuntimeEqual -Actual $payload.ProxyUri -Expected 'http://127.0.0.1:7897' -Label 'Elevation proxy payload'
            Assert-RuntimeEqual -Actual ([Environment]::GetEnvironmentVariable($environmentName, 'Process')) -Expected $null -Label 'Elevation environment cleanup'
            Assert-RuntimeThrows -Action { Get-BootstrapElevationPayload -Id $id } -Label 'Elevation payload reuse'
        }
        finally {
            [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
        }
    }

    It 'round-trips canonical options through the authenticated handoff without putting them in the command line' {
        InModuleScope Win11Bootstrap {
            $script:capturedElevationPayload = $null
            $script:capturedElevationCommandLength = 0
            $script:capturedElevationClient = $null
            Mock Send-BootstrapElevationEnvelope {
                param($Server, $ExpectedClientProcessId, $EnvelopeBytes, $TimeoutMilliseconds)
                $envelopeJson = [Text.Encoding]::UTF8.GetString([byte[]]$EnvelopeBytes)
                $envelope = ConvertFrom-Json -InputObject $envelopeJson -ErrorAction Stop
                $payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$envelope.OptionPayload))
                $script:capturedElevationPayload = ConvertFrom-Json -InputObject $payloadJson -ErrorAction Stop
                if ([string]$envelope.LoaderScript -notmatch 'Runtime snapshot source changed before copy') {
                    throw 'The authenticated envelope did not contain the reviewed runtime loader.'
                }
                if ($ExpectedClientProcessId -le 0) {
                    throw 'The handoff was not bound to a valid elevated process ID.'
                }
            }
            Mock Receive-BootstrapElevationResult { return 0 }
            Mock Start-Process {
                param($FilePath, $Verb, $ArgumentList, $WorkingDirectory, $PassThru, $ErrorAction)
                $encodedMatch = [regex]::Match($ArgumentList, '-EncodedCommand\s+([A-Za-z0-9+/=]+)$')
                if (-not $encodedMatch.Success) {
                    throw 'The elevation pipe client was not passed as a single encoded command.'
                }
                $wrapper = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value))
                if ($wrapper -notmatch 'ScriptBlock\]::Create' -or $wrapper -match '(?i)Invoke-Expression|\bIEX\b') {
                    throw 'The compressed elevation wrapper did not use the approved ScriptBlock creation path.'
                }
                $compressedMatch = [regex]::Match($wrapper, "FromBase64String\('([A-Za-z0-9+/=]+)'\)")
                if (-not $compressedMatch.Success) {
                    throw 'The compressed loader data was not found in the wrapper.'
                }
                $compressedBytes = [Convert]::FromBase64String($compressedMatch.Groups[1].Value)
                $memory = New-Object IO.MemoryStream(, $compressedBytes)
                $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Decompress)
                $reader = New-Object IO.StreamReader($gzip, [Text.Encoding]::UTF8)
                $loader = $reader.ReadToEnd()
                $reader.Dispose()
                $gzip.Dispose()
                $memory.Dispose()
                if ($loader -notmatch 'NamedPipeClientStream' -or $loader -notmatch 'GetNamedPipeServerProcessId' -or
                    $loader -match 'WIN11_TEST_SENTINEL|\"Only\"|OptionPayload\s*=') {
                    throw 'The elevated command exposed payload data or omitted authenticated pipe validation.'
                }
                $script:capturedElevationClient = $loader
                $script:capturedElevationCommandLength = $FilePath.Length + 1 + $ArgumentList.Length
                $processInfo = New-Object Diagnostics.ProcessStartInfo
                $processInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
                $processInfo.Arguments = '/d /c exit 0'
                $processInfo.UseShellExecute = $false
                $processInfo.CreateNoWindow = $true
                return [Diagnostics.Process]::Start($processInfo)
            }
            Mock Get-TrustedSystemExecutablePath { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }

            $exitCode = Start-BootstrapElevated -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1') -Invocation @{
                Only = @('git')
                Yes = [System.Management.Automation.SwitchParameter]::new($true)
                NoGitHubMirrors = [System.Management.Automation.SwitchParameter]::new($true)
                SeedDirectory = 'C:\WIN11_TEST_SENTINEL'
            }

            $mismatches = @()
            if ($exitCode -ne 0) { $mismatches += "exit=$exitCode" }
            if ($script:capturedElevationPayload.Yes.GetType().FullName -cne 'System.Boolean' -or
                $script:capturedElevationPayload.Yes -ne $true) { $mismatches += 'Yes' }
            if ($script:capturedElevationPayload.NoGitHubMirrors.GetType().FullName -cne 'System.Boolean' -or
                $script:capturedElevationPayload.NoGitHubMirrors -ne $true) { $mismatches += 'NoGitHubMirrors' }
            if ($script:capturedElevationPayload.SeedDirectory -cne 'C:\WIN11_TEST_SENTINEL') { $mismatches += 'SeedDirectory' }
            if ($script:capturedElevationClient -match 'WIN11_TEST_SENTINEL') { $mismatches += 'command-payload-leak' }
            if ($script:capturedElevationCommandLength -ge 12000) { $mismatches += "length=$($script:capturedElevationCommandLength)" }
            if ($mismatches.Count -ne 0) {
                throw ('Canonical options did not round-trip through the authenticated handoff: {0}.' -f ($mismatches -join ', '))
            }
        }
    }

    It 'restricts the elevation pipe to the caller and SYSTEM while denying network logons' {
        InModuleScope Win11Bootstrap {
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $systemSid = New-Object Security.Principal.SecurityIdentifier(
                    [Security.Principal.WellKnownSidType]::LocalSystemSid,
                    $null
                )
                $networkSid = New-Object Security.Principal.SecurityIdentifier(
                    [Security.Principal.WellKnownSidType]::NetworkSid,
                    $null
                )
                $expected = @{
                    $identity.User.Value = [Security.AccessControl.AccessControlType]::Allow
                    $systemSid.Value = [Security.AccessControl.AccessControlType]::Allow
                    $networkSid.Value = [Security.AccessControl.AccessControlType]::Deny
                }
                if (-not $server.CanWrite -or $server.CanRead -or
                    -not $resultServer.CanRead -or $resultServer.CanWrite) {
                    throw 'An elevation pipe has a direction outside the reviewed one-way policy.'
                }
                foreach ($securedServer in @($server, $resultServer)) {
                    $acl = $securedServer.GetAccessControl()
                    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                    if (-not $acl.AreAccessRulesProtected -or
                        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $identity.User.Value -or
                        $rules.Count -ne $expected.Count) {
                        throw 'The elevation pipe ACL header is not the exact reviewed policy.'
                    }
                    foreach ($rule in $rules) {
                        $sid = $rule.IdentityReference.Value
                        if (-not $expected.ContainsKey($sid) -or
                            $rule.AccessControlType -ne $expected[$sid] -or
                            $rule.PipeAccessRights -ne [IO.Pipes.PipeAccessRights]::FullControl -or
                            $rule.IsInherited) {
                            throw 'The elevation pipe ACL contains an unexpected rule.'
                        }
                    }
                }
            }
            finally {
                $server.Dispose()
                $resultServer.Dispose()
            }
        }
    }

    It 'moves a canonical payload through a real authenticated local pipe child process' {
        InModuleScope Win11Bootstrap {
            $id = [Guid]::NewGuid().ToString('N')
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $optionPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"Only":["git"],"Yes":true}'))
            $environmentName = 'WIN11_BOOTSTRAP_ELEVATION_{0}' -f $id.ToUpperInvariant()
            $loader = "if ([Environment]::GetEnvironmentVariable('$environmentName','Process') -ceq '$optionPayload') { return 0 }; return 20"
            [byte[]]$envelopeBytes = ConvertTo-BootstrapElevationEnvelopeBytes `
                -InvocationId $id `
                -OptionPayload $optionPayload `
                -LoaderScript $loader
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName $pipeName `
                -ResultPipeName $resultPipeName `
                -ExpectedServerProcessId $PID `
                -InvocationId $id `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 (Get-ByteArraySha256Hex -Bytes $envelopeBytes)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $processInfo.Arguments = $arguments
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardError = $true
            $process = $null
            try {
                $process = [Diagnostics.Process]::Start($processInfo)
                Send-BootstrapElevationEnvelope `
                    -Server $server `
                    -ExpectedClientProcessId $process.Id `
                    -EnvelopeBytes $envelopeBytes `
                    -TimeoutMilliseconds 30000
                $server.Dispose()
                $server = $null
                $reportedExitCode = Receive-BootstrapElevationResult `
                    -Server $resultServer `
                    -ExpectedClientProcessId $process.Id `
                    -ExpectedInvocationId $id `
                    -Process $process `
                    -TimeoutMilliseconds 30000
                $resultServer.Dispose()
                $resultServer = $null
                $process.WaitForExit()
                $errorText = $process.StandardError.ReadToEnd()
                if ($reportedExitCode -ne 0 -or $process.ExitCode -ne 0 -or $errorText -match 'Secure elevation .*failed|rejected unsafe state' -or
                    -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($environmentName, 'Process'))) {
                    throw "The real local elevation handoff child failed: reported=$reportedExitCode; exit=$($process.ExitCode); stderr=$errorText"
                }
            }
            finally {
                if ($null -ne $server) { $server.Dispose() }
                if ($null -ne $resultServer) { $resultServer.Dispose() }
                if ($null -ne $process) { $process.Dispose() }
                [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
            }
        }
    }

    It 'preserves a nonzero stable exit code through the real authenticated local pipe child process' {
        InModuleScope Win11Bootstrap {
            $id = [Guid]::NewGuid().ToString('N')
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $optionPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
            [byte[]]$envelopeBytes = ConvertTo-BootstrapElevationEnvelopeBytes `
                -InvocationId $id `
                -OptionPayload $optionPayload `
                -LoaderScript 'return 10'
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName $pipeName `
                -ResultPipeName $resultPipeName `
                -ExpectedServerProcessId $PID `
                -InvocationId $id `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 (Get-ByteArraySha256Hex -Bytes $envelopeBytes)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $processInfo.Arguments = $arguments
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardError = $true
            $process = $null
            try {
                $process = [Diagnostics.Process]::Start($processInfo)
                Send-BootstrapElevationEnvelope `
                    -Server $server `
                    -ExpectedClientProcessId $process.Id `
                    -EnvelopeBytes $envelopeBytes `
                    -TimeoutMilliseconds 30000
                $server.Dispose()
                $server = $null
                $reportedExitCode = Receive-BootstrapElevationResult `
                    -Server $resultServer `
                    -ExpectedClientProcessId $process.Id `
                    -ExpectedInvocationId $id `
                    -Process $process `
                    -TimeoutMilliseconds 30000
                $resultServer.Dispose()
                $resultServer = $null
                $process.WaitForExit()
                $errorText = $process.StandardError.ReadToEnd()
                if ($reportedExitCode -ne 10 -or $process.ExitCode -ne 10 -or $errorText -match 'Secure elevation .*failed|rejected unsafe state') {
                    throw "The real local elevation handoff collapsed exit code 10: reported=$reportedExitCode; exit=$($process.ExitCode); stderr=$errorText"
                }
            }
            finally {
                if ($null -ne $server) { $server.Dispose() }
                if ($null -ne $resultServer) { $resultServer.Dispose() }
                if ($null -ne $process) { $process.Dispose() }
            }
        }
    }

    It 'fails closed for an unexpected result client, malformed result frame, and missing result' {
        InModuleScope Win11Bootstrap {
            function Start-TestElevationResultClient {
                param(
                    [Parameter(Mandatory = $true)]
                    [string]$PipeName,

                    [Parameter(Mandatory = $true)]
                    [string]$Frame
                )

                $template = @'
$ErrorActionPreference = 'Stop'
$client = [IO.Pipes.NamedPipeClientStream]::new(
    '.',
    '__PIPE_NAME__',
    [IO.Pipes.PipeDirection]::Out,
    [IO.Pipes.PipeOptions]::Asynchronous,
    [Security.Principal.TokenImpersonationLevel]::Impersonation
)
try {
    $client.Connect(30000)
    [byte[]]$bytes = [Text.Encoding]::UTF8.GetBytes('__FRAME__')
    $client.Write($bytes, 0, $bytes.Length)
    $client.Flush()
}
finally {
    $client.Dispose()
}
Start-Sleep -Milliseconds 750
'@
                $clientScript = $template.Replace('__PIPE_NAME__', $PipeName)
                $clientScript = $clientScript.Replace('__FRAME__', $Frame)
                $processInfo = New-Object Diagnostics.ProcessStartInfo
                $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
                $processInfo.Arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $clientScript
                $processInfo.UseShellExecute = $false
                $processInfo.CreateNoWindow = $true
                return [Diagnostics.Process]::Start($processInfo)
            }

            $id = [Guid]::NewGuid().ToString('N')
            $validFrame = 'W11B1:{0}:10' -f $id

            $wrongPidPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $wrongPidServer = New-BootstrapElevationPipeServer -PipeName $wrongPidPipeName -Receive
            $wrongPidProcess = Start-TestElevationResultClient -PipeName $wrongPidPipeName -Frame $validFrame
            $wrongPidRejected = $false
            try {
                try {
                    [void](Receive-BootstrapElevationResult `
                        -Server $wrongPidServer `
                        -ExpectedClientProcessId ($wrongPidProcess.Id + 1) `
                        -ExpectedInvocationId $id `
                        -Process $wrongPidProcess `
                        -TimeoutMilliseconds 30000)
                }
                catch [System.Security.SecurityException] {
                    $wrongPidRejected = $_.Exception.Message -match 'unexpected process'
                }
            }
            finally {
                $wrongPidServer.Dispose()
                [void]$wrongPidProcess.WaitForExit(5000)
                $wrongPidProcess.Dispose()
            }
            if (-not $wrongPidRejected) {
                throw 'An elevation result from an unexpected client PID was accepted.'
            }

            $malformedPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $malformedServer = New-BootstrapElevationPipeServer -PipeName $malformedPipeName -Receive
            $malformedProcess = Start-TestElevationResultClient `
                -PipeName $malformedPipeName `
                -Frame ('W11B1:{0}:99' -f $id)
            $malformedRejected = $false
            try {
                try {
                    [void](Receive-BootstrapElevationResult `
                        -Server $malformedServer `
                        -ExpectedClientProcessId $malformedProcess.Id `
                        -ExpectedInvocationId $id `
                        -Process $malformedProcess `
                        -TimeoutMilliseconds 30000)
                }
                catch [System.Security.SecurityException] {
                    $malformedRejected = $_.Exception.Message -match 'frame is invalid'
                }
            }
            finally {
                $malformedServer.Dispose()
                [void]$malformedProcess.WaitForExit(5000)
                $malformedProcess.Dispose()
            }
            if (-not $malformedRejected) {
                throw 'An elevation result with an undocumented status was accepted.'
            }

            $missingPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $missingServer = New-BootstrapElevationPipeServer -PipeName $missingPipeName -Receive
            $missingProcessInfo = New-Object Diagnostics.ProcessStartInfo
            $missingProcessInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $missingProcessInfo.Arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript 'exit 0'
            $missingProcessInfo.UseShellExecute = $false
            $missingProcessInfo.CreateNoWindow = $true
            $missingProcess = [Diagnostics.Process]::Start($missingProcessInfo)
            $missingRejected = $false
            try {
                try {
                    [void](Receive-BootstrapElevationResult `
                        -Server $missingServer `
                        -ExpectedClientProcessId $missingProcess.Id `
                        -ExpectedInvocationId $id `
                        -Process $missingProcess `
                        -TimeoutMilliseconds 30000)
                }
                catch [InvalidOperationException] {
                    $missingRejected = $_.Exception.Message -match 'without returning an authenticated result'
                }
            }
            finally {
                $missingServer.Dispose()
                [void]$missingProcess.WaitForExit(5000)
                $missingProcess.Dispose()
            }
            if (-not $missingRejected) {
                throw 'An elevated child that omitted the authenticated result was accepted.'
            }
        }
    }

    It 'maps an elevation handoff hash mismatch to security failure without running the loader' {
        InModuleScope Win11Bootstrap {
            $id = [Guid]::NewGuid().ToString('N')
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $optionPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
            [byte[]]$envelopeBytes = ConvertTo-BootstrapElevationEnvelopeBytes `
                -InvocationId $id `
                -OptionPayload $optionPayload `
                -LoaderScript 'return 0'
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName $pipeName `
                -ResultPipeName $resultPipeName `
                -ExpectedServerProcessId $PID `
                -InvocationId $id `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 ('0' * 64)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $processInfo.Arguments = $arguments
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardError = $true
            $process = $null
            try {
                $process = [Diagnostics.Process]::Start($processInfo)
                Send-BootstrapElevationEnvelope `
                    -Server $server `
                    -ExpectedClientProcessId $process.Id `
                    -EnvelopeBytes $envelopeBytes `
                    -TimeoutMilliseconds 30000
                $server.Dispose()
                $server = $null
                $reportedExitCode = Receive-BootstrapElevationResult `
                    -Server $resultServer `
                    -ExpectedClientProcessId $process.Id `
                    -ExpectedInvocationId $id `
                    -Process $process `
                    -TimeoutMilliseconds 30000
                $resultServer.Dispose()
                $resultServer = $null
                $process.WaitForExit()
                $errorText = $process.StandardError.ReadToEnd()
                if ($reportedExitCode -ne 30 -or $process.ExitCode -ne 30 -or $errorText -notmatch 'envelope hash is invalid') {
                    throw "A mismatched handoff hash was not rejected as a security failure: reported=$reportedExitCode; exit=$($process.ExitCode); stderr=$errorText"
                }
            }
            finally {
                if ($null -ne $server) { $server.Dispose() }
                if ($null -ne $resultServer) { $resultServer.Dispose() }
                if ($null -ne $process) { $process.Dispose() }
            }
        }
    }

    It 'maps a malformed authenticated elevation envelope to security failure' {
        InModuleScope Win11Bootstrap {
            $id = [Guid]::NewGuid().ToString('N')
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            [byte[]]$envelopeBytes = [Text.Encoding]::UTF8.GetBytes('{not-json')
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName $pipeName `
                -ResultPipeName $resultPipeName `
                -ExpectedServerProcessId $PID `
                -InvocationId $id `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 (Get-ByteArraySha256Hex -Bytes $envelopeBytes)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $processInfo.Arguments = $arguments
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardError = $true
            $process = $null
            try {
                $process = [Diagnostics.Process]::Start($processInfo)
                Send-BootstrapElevationEnvelope `
                    -Server $server `
                    -ExpectedClientProcessId $process.Id `
                    -EnvelopeBytes $envelopeBytes `
                    -TimeoutMilliseconds 30000
                $server.Dispose()
                $server = $null
                $reportedExitCode = Receive-BootstrapElevationResult `
                    -Server $resultServer `
                    -ExpectedClientProcessId $process.Id `
                    -ExpectedInvocationId $id `
                    -Process $process `
                    -TimeoutMilliseconds 30000
                $resultServer.Dispose()
                $resultServer = $null
                $process.WaitForExit()
                $errorText = $process.StandardError.ReadToEnd()
                if ($reportedExitCode -ne 30 -or $process.ExitCode -ne 30 -or $errorText -notmatch 'encoding or JSON is invalid') {
                    throw "A malformed authenticated envelope was not rejected as a security failure: reported=$reportedExitCode; exit=$($process.ExitCode); stderr=$errorText"
                }
            }
            finally {
                if ($null -ne $server) { $server.Dispose() }
                if ($null -ne $resultServer) { $resultServer.Dispose() }
                if ($null -ne $process) { $process.Dispose() }
            }
        }
    }

    It 'refuses an unexpected pipe client PID before sending the envelope' {
        InModuleScope Win11Bootstrap {
            $id = [Guid]::NewGuid().ToString('N')
            $pipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $resultPipeName = 'win11-bootstrap-' + ([Guid]::NewGuid().ToString('N'))
            $optionPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
            [byte[]]$envelopeBytes = ConvertTo-BootstrapElevationEnvelopeBytes `
                -InvocationId $id `
                -OptionPayload $optionPayload `
                -LoaderScript 'return 0'
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName $pipeName `
                -ResultPipeName $resultPipeName `
                -ExpectedServerProcessId $PID `
                -InvocationId $id `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 (Get-ByteArraySha256Hex -Bytes $envelopeBytes)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $server = New-BootstrapElevationPipeServer -PipeName $pipeName
            $resultServer = New-BootstrapElevationPipeServer -PipeName $resultPipeName -Receive
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            $processInfo.Arguments = $arguments
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $process = $null
            $rejected = $false
            try {
                $process = [Diagnostics.Process]::Start($processInfo)
                try {
                    Send-BootstrapElevationEnvelope `
                        -Server $server `
                        -ExpectedClientProcessId ($process.Id + 1) `
                        -EnvelopeBytes $envelopeBytes `
                        -TimeoutMilliseconds 30000
                }
                catch [System.Security.SecurityException] {
                    $rejected = $true
                }
                $server.Dispose()
                $server = $null
                $reportedExitCode = Receive-BootstrapElevationResult `
                    -Server $resultServer `
                    -ExpectedClientProcessId $process.Id `
                    -ExpectedInvocationId $id `
                    -Process $process `
                    -TimeoutMilliseconds 30000
                $resultServer.Dispose()
                $resultServer = $null
                [void]$process.WaitForExit(30000)
                if (-not $rejected -or $reportedExitCode -ne 20) {
                    throw 'The pipe server sent data without matching the elevated client PID.'
                }
            }
            finally {
                if ($null -ne $server) { $server.Dispose() }
                if ($null -ne $resultServer) { $resultServer.Dispose() }
                if ($null -ne $process) { $process.Dispose() }
            }
        }
    }

    It 'uses the authenticated result when ShellExecute collapses a nonzero child exit code' {
        InModuleScope Win11Bootstrap {
            Mock Send-BootstrapElevationEnvelope { }
            Mock Receive-BootstrapElevationResult { return 10 }
            Mock Start-Process {
                $processInfo = New-Object Diagnostics.ProcessStartInfo
                $processInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
                $processInfo.Arguments = '/d /c exit 1'
                $processInfo.UseShellExecute = $false
                $processInfo.CreateNoWindow = $true
                return [Diagnostics.Process]::Start($processInfo)
            }
            Mock Get-TrustedSystemExecutablePath { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            $exitCode = Start-BootstrapElevated `
                -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1') `
                -Invocation @{ Only = @('git'); Yes = $true }
            if ($exitCode -ne 10) {
                throw 'The authenticated stable result was replaced by the collapsed ShellExecute exit code.'
            }
        }
    }

    It 'fails closed when a runtime snapshot source changes after manifest creation' {
        $snapshotRoot = Join-Path $TestDrive 'snapshot-source'
        foreach ($directory in @($snapshotRoot, (Join-Path $snapshotRoot 'src'), (Join-Path $snapshotRoot 'catalog'), (Join-Path $snapshotRoot 'resources'))) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        'entry' | Set-Content -LiteralPath (Join-Path $snapshotRoot 'bootstrap.ps1') -Encoding ascii
        'module' | Set-Content -LiteralPath (Join-Path $snapshotRoot 'src\Win11Bootstrap.psm1') -Encoding ascii
        'catalog' | Set-Content -LiteralPath (Join-Path $snapshotRoot 'catalog\apps.psd1') -Encoding ascii
        'resource' | Set-Content -LiteralPath (Join-Path $snapshotRoot 'resources\strings.zh-CN.json') -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_SNAPSHOT_ROOT', $snapshotRoot, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $root = [Environment]::GetEnvironmentVariable('WIN11_TEST_SNAPSHOT_ROOT', 'Process')
                $manifest = Get-BootstrapRuntimeSnapshotManifest -ScriptPath (Join-Path $root 'bootstrap.ps1')
                'tampered' | Set-Content -LiteralPath (Join-Path $root 'catalog\apps.psd1') -Encoding ascii
                $caught = $false
                try { Assert-BootstrapRuntimeSnapshotManifest -Manifest $manifest }
                catch [System.Security.SecurityException] { $caught = $true }
                if (-not $caught) {
                    throw 'A changed runtime snapshot source was not rejected.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_SNAPSHOT_ROOT', $null, 'Process')
        }
    }

    It 'fails closed when a runtime snapshot manifest length does not exactly match the source' {
        InModuleScope Win11Bootstrap {
            $manifest = Get-BootstrapRuntimeSnapshotManifest -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1')
            $manifest.Files[0].Length = [long]$manifest.Files[0].Length + 1
            $caught = $false
            try { Assert-BootstrapRuntimeSnapshotManifest -Manifest $manifest }
            catch [System.Security.SecurityException] { $caught = $true }
            if (-not $caught) {
                throw 'A runtime snapshot source with the wrong manifest length was accepted.'
            }
        }
    }

    It 'rejects a reparse point before creating secure ProgramData state' {
        $junctionTarget = Join-Path $TestDrive 'junction-target'
        $junctionPath = Join-Path $TestDrive 'junction-path'
        [void](New-Item -ItemType Directory -Path $junctionTarget -Force)
        [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -Force)
        [Environment]::SetEnvironmentVariable('WIN11_TEST_JUNCTION_PATH', $junctionPath, 'Process')
        try {
            InModuleScope Win11Bootstrap {
            $path = [Environment]::GetEnvironmentVariable('WIN11_TEST_JUNCTION_PATH', 'Process')
            $caught = $false
            try { Assert-RegularBootstrapDirectory -Path $path }
            catch [System.Security.SecurityException] { $caught = $true }
            if (-not $caught) {
                throw 'A bootstrap directory reparse point was not rejected.'
            }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_JUNCTION_PATH', $null, 'Process')
        }
    }

    It 'refuses to take over a pre-existing permissive bootstrap directory' {
        $looseDirectory = Join-Path $TestDrive 'preexisting-permissive'
        [void](New-Item -ItemType Directory -Path $looseDirectory -Force)
        $before = (Get-Acl -LiteralPath $looseDirectory).Sddl
        [Environment]::SetEnvironmentVariable('WIN11_TEST_LOOSE_DIRECTORY', $looseDirectory, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $path = [Environment]::GetEnvironmentVariable('WIN11_TEST_LOOSE_DIRECTORY', 'Process')
                $caught = $false
                try { [void](Assert-SecureDirectory -Path $path -ExpectedSecurity (New-RestrictedDirectorySecurity)) }
                catch [System.Security.SecurityException] { $caught = $true }
                if (-not $caught) {
                    throw 'A pre-existing permissive directory was accepted or silently tightened.'
                }
            }
            $after = (Get-Acl -LiteralPath $looseDirectory).Sddl
            if ($after -cne $before) {
                throw 'Security validation mutated the pre-existing directory ACL.'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_LOOSE_DIRECTORY', $null, 'Process')
        }
    }

    It 'creates elevated logs with an atomic random filename in the secure directory' {
        [Environment]::SetEnvironmentVariable('WIN11_TEST_LOG_ROOT', $TestDrive, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Test-IsAdministrator { $true }
                Mock New-SecureBootstrapSubdirectory { [Environment]::GetEnvironmentVariable('WIN11_TEST_LOG_ROOT', 'Process') }
                Initialize-BootstrapLog
                $first = $script:LogPath
                Initialize-BootstrapLog
                $second = $script:LogPath
                if ($first -eq $second -or
                    [IO.Path]::GetFileName($first) -notmatch '^bootstrap-\d{8}-\d{6}-[a-f0-9]{32}\.log$' -or
                    -not [IO.File]::Exists($first) -or -not [IO.File]::Exists($second)) {
                    throw 'Secure log creation did not use unique atomic files.'
                }
                $script:LogPath = $null
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_LOG_ROOT', $null, 'Process')
        }
    }

    It 'builds a parseable fail-closed elevation loader with guarded cleanup under budget' {
        [Environment]::SetEnvironmentVariable('WIN11_TEST_CLEANUP_ROOT', $TestDrive, 'Process')
        try {
            InModuleScope Win11Bootstrap {
            $manifest = Get-BootstrapRuntimeSnapshotManifest -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1')
            $loader = Get-BootstrapElevationLoaderScript -Manifest $manifest -PayloadId ('a' * 32)
            $loaderBlock = [Management.Automation.ScriptBlock]::Create($loader)
            if ($loader -notmatch 'finally\s*\{' -or
                $loader -notmatch 'Remove-LockedSnapshot' -or
                $loader -notmatch 'Refusing to recursively clean a runtime tree containing a reparse point' -or
                $loader -notmatch 'Runtime snapshot source changed before copy' -or
                $loader -notmatch 'sourceItem\.Length\s+-ne\s+\[long\]\$entry\.Length' -or
                $loader -notmatch 'destinationItem\.Length\s+-ne\s+\[long\]\$entry\.Length' -or
                $loader -match '\.SetAccessControl\s*\(' -or
                $loader -notmatch 'Secure runtime owner is unexpected' -or
                $loader -notmatch 'FileSystemRights\]::FullControl' -or
                $loader -notmatch 'Secure elevation bootstrap rejected unsafe runtime state' -or
                $loader -notmatch '\$exitCode\s*=\s*30') {
                throw 'The elevation loader is missing fail-closed copy or guarded-cleanup behavior.'
            }
            $optionPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
            [byte[]]$envelopeBytes = ConvertTo-BootstrapElevationEnvelopeBytes `
                -InvocationId ('a' * 32) `
                -OptionPayload $optionPayload `
                -LoaderScript $loader
            $client = Get-BootstrapElevationPipeClientScript `
                -PipeName ('win11-bootstrap-' + ('b' * 32)) `
                -ResultPipeName ('win11-bootstrap-' + ('c' * 32)) `
                -ExpectedServerProcessId $PID `
                -InvocationId ('a' * 32) `
                -ExpectedLength $envelopeBytes.Length `
                -ExpectedSha256 (Get-ByteArraySha256Hex -Bytes $envelopeBytes)
            [void][Management.Automation.ScriptBlock]::Create($client)
            $arguments = ConvertTo-BootstrapEncodedLoaderArguments -LoaderScript $client
            $powerShellPath = Get-TrustedSystemExecutablePath -RelativePath 'WindowsPowerShell\v1.0\powershell.exe'
            if (($powerShellPath.Length + 1 + $arguments.Length) -ge 12000 -or
                $client -notmatch 'GetNamedPipeServerProcessId' -or
                $client -notmatch 'The elevation handoff envelope hash is invalid') {
                throw 'The complete elevation command exceeds the conservative command-line budget.'
            }

            $encodedMatch = [regex]::Match($arguments, '-EncodedCommand\s+([A-Za-z0-9+/=]+)$')
            $outerWrapper = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value))
            [void][Management.Automation.ScriptBlock]::Create($outerWrapper)
            if ($outerWrapper -notmatch 'catch \[Security\.SecurityException\]' -or
                $outerWrapper -notmatch 'Secure elevation wrapper failed') {
                throw 'The outer elevation decoder did not map failures to stable exit codes.'
            }

            $cleanupFunction = $loaderBlock.Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-LockedSnapshot'
            }, $true)
            if ($null -eq $cleanupFunction) {
                throw 'The guarded runtime cleanup function was not present in the loader AST.'
            }
            $cleanupScript = [Management.Automation.ScriptBlock]::Create(
                "param([string]`$Target,[string]`$Root)`n" + $cleanupFunction.Extent.Text + "`nRemove-LockedSnapshot -Path `$Target -RuntimeRoot `$Root"
            )
            $testRoot = [Environment]::GetEnvironmentVariable('WIN11_TEST_CLEANUP_ROOT', 'Process')
            $runtimeRoot = Join-Path $testRoot 'runtime-cleanup'
            [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
            $safeLeaf = Join-Path $runtimeRoot ([Guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $safeLeaf)
            'runtime' | Set-Content -LiteralPath (Join-Path $safeLeaf 'file.txt') -Encoding ascii
            & $cleanupScript $safeLeaf $runtimeRoot
            if (Test-Path -LiteralPath $safeLeaf) {
                throw 'A regular secure runtime snapshot was not cleaned.'
            }

            $unsafeLeaf = Join-Path $runtimeRoot ([Guid]::NewGuid().ToString('N'))
            $junctionTarget = Join-Path $testRoot 'cleanup-junction-target'
            [void](New-Item -ItemType Directory -Path $unsafeLeaf)
            [void](New-Item -ItemType Directory -Path $junctionTarget -Force)
            [void](New-Item -ItemType Junction -Path (Join-Path $unsafeLeaf 'link') -Target $junctionTarget)
            $cleanupRejected = $false
            try { & $cleanupScript $unsafeLeaf $runtimeRoot }
            catch { $cleanupRejected = $true }
            if (-not $cleanupRejected -or -not (Test-Path -LiteralPath $unsafeLeaf)) {
                throw 'Guarded cleanup did not fail closed on a descendant reparse point.'
            }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_CLEANUP_ROOT', $null, 'Process')
        }
    }

    It 'refuses to carry an external config path across the elevation boundary' {
        InModuleScope Win11Bootstrap {
            $caught = $false
            try {
                Start-BootstrapElevated -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1') -Invocation @{ Config = 'C:\untrusted\options.json' }
            }
            catch [System.Security.SecurityException] { $caught = $true }
            if (-not $caught) {
                throw 'An external config path crossed the elevation boundary.'
            }
        }
    }

    It 'returns usage exit code 64 for unknown or incomplete command-line parameters' {
        $bootstrapPath = Join-Path $script:RepositoryRoot 'bootstrap.ps1'
        $unknownResult = & $script:InvokeBootstrapChildProcess -BootstrapPath $bootstrapPath -ArgumentText '-UnknownBootstrapOption'
        Assert-RuntimeEqual -Actual $unknownResult.ExitCode -Expected 64 -Label 'Unknown parameter exit code'
        if ($unknownResult.StandardError -notmatch 'Parameter error:') {
            throw 'Unknown parameter failure did not emit the stable usage error category.'
        }

        $missingValueResult = & $script:InvokeBootstrapChildProcess -BootstrapPath $bootstrapPath -ArgumentText '-Config'
        Assert-RuntimeEqual -Actual $missingValueResult.ExitCode -Expected 64 -Label 'Missing parameter value exit code'
        if ($missingValueResult.StandardError -notmatch 'Parameter error:') {
            throw 'Missing parameter value did not emit the stable usage error category.'
        }
    }

    It 'maps elevation and secure-log policy failures to exit code 30' {
        InModuleScope Win11Bootstrap {
            Mock Assert-SupportedEnvironment { }
            Mock Test-IsAdministrator { $false }
            Mock Start-BootstrapElevated { throw [System.Security.SecurityException]::new('simulated unsafe snapshot') }
            $elevationCode = Invoke-Win11Bootstrap -Only @('git') -Yes -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1')
            if ($elevationCode -ne 30) {
                throw 'A secure elevation preflight failure did not map to exit code 30.'
            }

            Mock Test-IsAdministrator { $true }
            Mock Initialize-BootstrapLog { throw [System.Security.SecurityException]::new('simulated unsafe log directory') }
            $logCode = Invoke-Win11Bootstrap -Only @('git') -Yes -ScriptPath (Join-Path $script:RepositoryRoot 'bootstrap.ps1')
            if ($logCode -ne 30) {
                throw 'A secure log initialization failure did not map to exit code 30.'
            }
        }

        $bootstrapPath = Join-Path $script:RepositoryRoot 'bootstrap.ps1'
        $missingPayloadId = [Guid]::NewGuid().ToString('N')
        $payloadResult = & $script:InvokeBootstrapChildProcess -BootstrapPath $bootstrapPath -ArgumentText ("-ElevatedPayloadId $missingPayloadId")
        Assert-RuntimeEqual -Actual $payloadResult.ExitCode -Expected 30 -Label 'Missing elevation payload exit code'
        if ($payloadResult.StandardError -notmatch 'Bootstrap security policy failure:') {
            throw 'Missing elevation payload did not emit the stable security error category.'
        }
    }

    It 'writes stable summary keys and statuses to the file without duplicating console output' {
        $logPath = Join-Path $TestDrive 'summary.log'
        '' | Set-Content -LiteralPath $logPath -Encoding utf8
        [Environment]::SetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', $logPath, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $script:DryRun = $false
                $script:LogPath = [Environment]::GetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', 'Process')
                Mock Write-Host { }
                $results = @(
                    [pscustomobject]@{ Order = 1; Key = 'chrome'; Status = 'AlreadyInstalled'; Name = 'Chrome'; Detail = 'present'; Application = @{} },
                    [pscustomobject]@{ Order = 2; Key = 'git'; Status = 'Skipped'; Name = 'Git'; Detail = 'explicitly skipped'; Application = @{} },
                    [pscustomobject]@{ Order = 3; Key = 'xftp'; Status = 'ManualActionRequired'; Name = 'Xftp'; Detail = 'Visit https://alice:secret@example.test/action?token=abc'; Application = @{} },
                    [pscustomobject]@{ Order = 4; Key = 'realvnc-server'; Status = 'NonCompliant'; Name = 'RealVNC Server'; Detail = 'protected major'; Application = @{} }
                )

                Show-BootstrapSummary -Results $results

                $lines = @(Get-Content -LiteralPath $script:LogPath)
                $summaryLines = @($lines | Where-Object { $_ -match '\[INFO\] Result key=' })
                if ($summaryLines.Count -ne 4 -or
                    @($summaryLines | Where-Object { $_ -match 'key=chrome; status=AlreadyInstalled' }).Count -ne 1 -or
                    @($summaryLines | Where-Object { $_ -match 'key=git; status=Skipped' }).Count -ne 1 -or
                    @($summaryLines | Where-Object { $_ -match 'key=xftp; status=ManualActionRequired' }).Count -ne 1 -or
                    @($summaryLines | Where-Object { $_ -match 'key=realvnc-server; status=NonCompliant' }).Count -ne 1) {
                    throw 'The file summary did not contain each stable key and status exactly once.'
                }
                if (($summaryLines -join "`n") -match 'alice|secret|token=abc' -or ($summaryLines -join "`n") -notmatch '\*\*\*') {
                    throw 'A summary detail was not redacted before file logging.'
                }
                # Blank line, title, four rows, three details, rerun hint, and
                # log path are the only console writes. File-only rows add none.
                Assert-MockCalled Write-Host -Times 10 -Scope It
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', $null, 'Process')
        }
    }

    It 'does not create or append a summary log during WhatIf' {
        $logPath = Join-Path $TestDrive 'whatif-summary.log'
        [Environment]::SetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', $logPath, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $script:DryRun = $true
                $script:LogPath = [Environment]::GetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', 'Process')
                Mock Write-Host { }
                Show-BootstrapSummary -Results @(
                    [pscustomobject]@{ Order = 1; Key = 'git'; Status = 'AlreadyInstalled'; Name = 'Git'; Detail = ''; Application = @{} }
                )
                if (Test-Path -LiteralPath $script:LogPath) {
                    throw 'WhatIf summary unexpectedly wrote a log file.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_SUMMARY_LOG', $null, 'Process')
        }
    }
}

Describe 'Trusted provider boundaries' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        Import-Module -Name (Join-Path $script:RepositoryRoot 'src\Win11Bootstrap.psm1') -Force
    }

    It 'requires WinGet version and exact official source identities to succeed' {
        InModuleScope Win11Bootstrap {
            Mock Get-WingetCommandPath { 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_test\winget.exe' }
            Mock Invoke-WingetRaw {
                param($Arguments, $ProxyUri)
                if ($Arguments[0] -eq '--version') {
                    return [pscustomobject]@{ ExitCode = 0; Output = 'v1.10.0' }
                }
                if ($Arguments[2] -eq 'winget') {
                    return [pscustomobject]@{ ExitCode = 0; Output = '{"Arg":"https://cdn.winget.microsoft.com/cache","Data":"Microsoft.Winget.Source_8wekyb3d8bbwe","Explicit":false,"Identifier":"Microsoft.Winget.Source_8wekyb3d8bbwe","Name":"winget","TrustLevel":["Trusted","StoreOrigin"],"Type":"Microsoft.PreIndexed.Package"}' }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = '{"Arg":"https://storeedgefd.dsx.mp.microsoft.com/v9.0","Data":"","Explicit":false,"Identifier":"StoreEdgeFD","Name":"msstore","TrustLevel":["Trusted"],"Type":"Microsoft.Rest"}' }
            }
            if (-not (Test-WinGetFunctional)) {
                throw 'A functional WinGet with official sources failed the health probe.'
            }

            Mock Invoke-WingetRaw {
                param($Arguments, $ProxyUri)
                if ($Arguments[0] -eq '--version') {
                    return [pscustomobject]@{ ExitCode = 0; Output = 'v1.10.0' }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = '{"Arg":"https://attacker.example/cache","Data":"Microsoft.Winget.Source_8wekyb3d8bbwe","Explicit":false,"Identifier":"Microsoft.Winget.Source_8wekyb3d8bbwe","Name":"winget","TrustLevel":["Trusted","StoreOrigin"],"Type":"Microsoft.PreIndexed.Package"}' }
            }
            if (Test-WinGetFunctional) {
                throw 'WinGet passed health checks with a same-name source pointing at an unreviewed host.'
            }
        }
    }

    It 'fails closed before installation when a same-name WinGet source is altered' {
        InModuleScope Win11Bootstrap {
            Mock Test-TrustedWinGetSources { [pscustomobject]@{ Trusted = $false; Detail = 'winget source identity mismatch' } }
            Mock Invoke-WingetDirect { throw 'Install must not run with an untrusted source.' }
            $application = [pscustomobject]@{
                Name = 'Example'
                InstallerType = 'Winget'
                WingetId = 'Example.App'
                WingetSource = 'winget'
                WingetVersion = ''
            }
            $result = Invoke-WingetInstall -Application $application
            if ($result.FailureKind -ne 'NonCompliant') {
                throw 'An altered WinGet source was not surfaced as NonCompliant.'
            }
            Assert-MockCalled Invoke-WingetDirect -Times 0 -Scope It
        }
    }

    It 'pins the reviewed WinGet repair module and official PSGallery endpoint' {
        InModuleScope Win11Bootstrap {
            if ($script:WinGetClientVersion -cne '1.29.280') {
                throw 'The reviewed Microsoft.WinGet.Client version is not pinned.'
            }
            $definition = (Get-Command -Name Install-WinGetRepairModule -CommandType Function).Definition
            if ($definition -notmatch 'RequiredVersion\s+\$script:WinGetClientVersion' -or
                $definition -notmatch 'www\.powershellgallery\.com/api/v2' -or
                $definition -match 'Install-PackageProvider') {
                throw 'WinGet repair does not pin its module, validate PSGallery, or avoid an unpinned NuGet provider.'
            }
        }
    }

    It 'runs WinGet repair in the selected process proxy boundary and restores all proxy state' {
        InModuleScope Win11Bootstrap {
            $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
            $original = @{}
            foreach ($name in $names) {
                $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, "sentinel-$name", 'Process')
            }
            $sentinelProxy = New-Object Net.WebProxy([Uri]'http://127.0.0.1:65530')
            $originalDefaultProxy = [Net.WebRequest]::DefaultWebProxy
            [Net.WebRequest]::DefaultWebProxy = $sentinelProxy
            try {
                $script:repairProxyMode = 'direct'
                Mock Invoke-WinGetRepairModuleCore {
                    $target = [Uri]'https://www.powershellgallery.com/api/v2'
                    if ($script:repairProxyMode -eq 'direct') {
                        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
                            if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {
                                throw "Direct repair inherited process variable $name."
                            }
                        }
                        if ([Net.WebRequest]::DefaultWebProxy.GetProxy($target).AbsoluteUri -ne $target.AbsoluteUri) {
                            throw 'Direct repair inherited DefaultWebProxy.'
                        }
                    }
                    else {
                        if ([Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process') -cne 'http://127.0.0.1:7897/' -or
                            [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process') -cne 'http://127.0.0.1:7897/' -or
                            $null -ne [Environment]::GetEnvironmentVariable('ALL_PROXY', 'Process') -or
                            $null -ne [Environment]::GetEnvironmentVariable('NO_PROXY', 'Process') -or
                            [Net.WebRequest]::DefaultWebProxy.GetProxy($target).AbsoluteUri -ne 'http://127.0.0.1:7897/') {
                            throw 'Proxied repair did not receive the exact bounded proxy state.'
                        }
                    }
                    return $true
                }

                if (-not (Invoke-WinGetRepairWithModule -ProxyUri $null)) {
                    throw 'Direct repair operation did not complete.'
                }
                foreach ($name in $names) {
                    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne "sentinel-$name") {
                        throw "Direct repair did not restore $name."
                    }
                }
                if (-not [object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy, $sentinelProxy)) {
                    throw 'Direct repair did not restore DefaultWebProxy.'
                }

                $script:repairProxyMode = 'proxy'
                if (-not (Invoke-WinGetRepairWithModule -ProxyUri 'http://127.0.0.1:7897')) {
                    throw 'Proxied repair operation did not complete.'
                }
                foreach ($name in $names) {
                    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne "sentinel-$name") {
                        throw "Proxied repair did not restore $name."
                    }
                }
                if (-not [object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy, $sentinelProxy)) {
                    throw 'Proxied repair did not restore DefaultWebProxy.'
                }
                Assert-MockCalled Invoke-WinGetRepairModuleCore -Times 2 -Scope It
            }
            finally {
                [Net.WebRequest]::DefaultWebProxy = $originalDefaultProxy
                foreach ($name in $names) {
                    [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
                }
            }
        }
    }

    It 'passes direct and verified proxy choices into WinGet repair at the correct retry stage' {
        InModuleScope Win11Bootstrap {
            $script:repairProxyValues = New-Object System.Collections.Generic.List[string]
            $script:repairReady = $false
            Mock Test-WinGetFunctional { return $script:repairReady }
            Mock Get-WinGetSourceComplianceFailure { return $null }
            Mock Get-AppxPackage { return $null }
            Mock Get-Command { return $null }
            Mock Invoke-WinGetRepairWithModule {
                param($ProxyUri)
                [void]$script:repairProxyValues.Add($(if ([string]::IsNullOrWhiteSpace($ProxyUri)) { '<direct>' } else { $ProxyUri }))
                if ($script:repairProxyValues.Count -eq 2) {
                    $script:repairReady = $true
                    return $true
                }
                return $false
            }
            Mock Install-WinGetRepairModule {
                param($ProxyUri)
                if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) {
                    throw 'The direct recovery case unexpectedly received a proxy.'
                }
                return [pscustomobject]@{ Success = $true; NetworkFailure = $false; Detail = 'installed' }
            }

            $direct = Repair-WinGetAvailability
            if (-not $direct.Success -or @($script:repairProxyValues) -join '|' -cne '<direct>|<direct>') {
                throw 'Initial and post-install direct repairs were not explicitly proxy-free.'
            }

            $script:repairProxyValues.Clear()
            $script:repairReady = $false
            Mock Install-WinGetRepairModule {
                param($ProxyUri)
                if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
                    return [pscustomobject]@{ Success = $false; NetworkFailure = $true; Detail = 'network failure' }
                }
                return [pscustomobject]@{ Success = $true; NetworkFailure = $false; Detail = 'installed through proxy' }
            }
            Mock Get-ProxyCandidates { return @('http://127.0.0.1:7897/') }
            Mock Test-ProxyUri { return $true }

            $proxied = Repair-WinGetAvailability -ExplicitProxyUri 'http://127.0.0.1:7897'
            if (-not $proxied.Success -or @($script:repairProxyValues) -join '|' -cne '<direct>|http://127.0.0.1:7897/') {
                throw 'A verified proxy was not passed only to the proxied repair attempt.'
            }
        }
    }

    It 'does not retry WinGet repair through a proxy after a non-network failure' {
        InModuleScope Win11Bootstrap {
            Mock Test-WinGetFunctional { return $false }
            Mock Get-WinGetSourceComplianceFailure { return $null }
            Mock Get-AppxPackage { return $null }
            Mock Get-Command { return $null }
            Mock Invoke-WinGetRepairWithModule { return $false }
            Mock Install-WinGetRepairModule {
                return [pscustomobject]@{ Success = $false; NetworkFailure = $false; Detail = 'official source policy rejected the operation' }
            }
            Mock Get-ProxyCandidates { throw 'Proxy candidates must not be consulted for a non-network or security failure.' }

            $result = Repair-WinGetAvailability -ExplicitProxyUri 'http://127.0.0.1:7897'
            if ($result.Success -or $result.FailureKind -ne 'Failed') {
                throw 'A non-network WinGet repair failure did not stop retry processing.'
            }
            Assert-MockCalled Install-WinGetRepairModule -Times 1 -Scope It
            Assert-MockCalled Get-ProxyCandidates -Times 0 -Scope It
        }
    }

    It 'classifies WinGet security, restart, network, and ordinary failures' {
        InModuleScope Win11Bootstrap {
            if ((Get-WinGetFailureKind -ExitCode -1978335215) -ne 'NonCompliant' -or
                (Get-WinGetFailureKind -ExitCode -1978335222) -ne 'NonCompliant' -or
                (Get-WinGetFailureKind -ExitCode -1978334962) -ne 'NonCompliant' -or
                (Get-WinGetFailureKind -ExitCode -1978334967) -ne 'NeedsRestart' -or
                (Get-WinGetFailureKind -ExitCode -1978334969) -ne 'NeedsProxy' -or
                (Get-WinGetFailureKind -ExitCode -1978335098) -ne 'NeedsProxy' -or
                (Get-WinGetFailureKind -ExitCode -1978335117) -ne 'ManualActionRequired' -or
                (Get-WinGetFailureKind -ExitCode -1978335205) -ne 'ManualActionRequired' -or
                (Get-WinGetFailureKind -ExitCode -1978334961) -ne 'ManualActionRequired' -or
                (Get-WinGetFailureKind -ExitCode 1 -Output 'package not found') -ne 'Failed') {
                throw 'WinGet failure codes were not mapped to stable bootstrap states.'
            }
        }
    }

    It 'reports a WinGet proxy setting restoration failure as a security failure' {
        InModuleScope Win11Bootstrap {
            Mock Invoke-WingetRaw {
                param($Arguments, $ProxyUri)
                if ($Arguments[0] -eq 'source') {
                    return [pscustomobject]@{ ExitCode = 1; Output = 'ProxyCommandLineOptions is disabled' }
                }
                if ($Arguments[0] -eq 'settings' -and $Arguments[1] -eq '--enable') {
                    return [pscustomobject]@{ ExitCode = 0; Output = '' }
                }
                if ($Arguments[0] -eq 'settings' -and $Arguments[1] -eq '--disable') {
                    return [pscustomobject]@{ ExitCode = 1; Output = 'restore failed' }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $result = Invoke-WingetThroughProxy -Arguments @('install', '--id', 'Example.App') -ProxyUri 'http://127.0.0.1:7897'
            if (-not $result.SecurityFailure) {
                throw 'WinGet proxy feature restoration failure was not surfaced as a security failure.'
            }
        }
    }

    It 'makes a direct web request bypass and then restore the system proxy' {
        $originalProxy = [Net.WebRequest]::DefaultWebProxy
        $sentinelProxy = New-Object Net.WebProxy([Uri]'http://127.0.0.1:65530')
        [Net.WebRequest]::DefaultWebProxy = $sentinelProxy
        try {
            InModuleScope Win11Bootstrap {
                Mock Invoke-WebRequest {
                    $target = [Uri]'https://vendor.example/file'
                    $effective = [Net.WebRequest]::DefaultWebProxy.GetProxy($target)
                    if ($effective.AbsoluteUri -ne $target.AbsoluteUri) {
                        throw 'The direct request inherited a proxy.'
                    }
                    return [pscustomobject]@{ StatusCode = 200 }
                }
                [void](Invoke-WebRequestSafe -Uri ([Uri]'https://vendor.example/file'))
            }
            if (-not [object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy, $sentinelProxy)) {
                throw 'The system proxy object was not restored after a direct request.'
            }
        }
        finally {
            [Net.WebRequest]::DefaultWebProxy = $originalProxy
        }
    }

    It 'rejects an unreviewed intermediate redirect before sending the next request' {
        InModuleScope Win11Bootstrap {
            $script:redirectRequestCount = 0
            Mock Invoke-WebRequest {
                $script:redirectRequestCount++
                return [pscustomobject]@{
                    StatusCode = 302
                    Headers = @{ Location = 'https://unreviewed.example/payload.exe' }
                }
            }
            $blocked = $false
            try {
                [void](Invoke-WebRequestSafe -Uri ([Uri]'https://vendor.example/start.exe') -AllowedRedirectHosts @('vendor.example'))
            }
            catch [System.Security.SecurityException] {
                $blocked = $true
            }
            if (-not $blocked -or $script:redirectRequestCount -ne 1) {
                throw 'The redirect boundary sent a request to an unreviewed intermediate host.'
            }
        }
    }

    It 'accepts only reviewed final download hosts' {
        $destination = Join-Path $TestDrive 'redirect-test.exe'
        [Environment]::SetEnvironmentVariable('WIN11_TEST_DOWNLOAD', $destination, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Invoke-WebRequestSafe {
                    param($Uri, $ProxyUri, $OutFile, $TimeoutSeconds, $AllowedRedirectHosts)
                    'payload' | Set-Content -LiteralPath $OutFile -Encoding ascii
                    return [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [Uri]'https://vendor.example/final.exe' } }
                }
                $path = [Environment]::GetEnvironmentVariable('WIN11_TEST_DOWNLOAD', 'Process')
                $allowed = Save-DownloadAttempt -Uri ([Uri]'https://vendor.example/start.exe') -Destination $path -AllowedResponseHosts @('vendor.example')
                if (-not $allowed.Success) {
                    throw 'A reviewed final host was rejected.'
                }

                Mock Invoke-WebRequestSafe {
                    param($Uri, $ProxyUri, $OutFile, $TimeoutSeconds, $AllowedRedirectHosts)
                    'payload' | Set-Content -LiteralPath $OutFile -Encoding ascii
                    return [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [Uri]'https://unreviewed.example/final.exe' } }
                }
                $rejected = Save-DownloadAttempt -Uri ([Uri]'https://vendor.example/start.exe') -Destination $path -AllowedResponseHosts @('vendor.example')
                if (-not $rejected.SecurityFailure -or (Test-Path -LiteralPath $path)) {
                    throw 'An unreviewed redirect host was not rejected and removed.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_DOWNLOAD', $null, 'Process')
        }
    }

    It 'parses WSL verbose output and retains the reported version' {
        $fakeWsl = Join-Path $TestDrive 'fake-wsl.cmd'
        @'
@echo off
echo   NAME              STATE       VERSION
echo * Ubuntu-24.04      Stopped     2
echo   Ubuntu-22.04      Stopped     1
exit /b 0
'@ | Set-Content -LiteralPath $fakeWsl -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $fakeWsl, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Get-TrustedSystemExecutablePath { [Environment]::GetEnvironmentVariable('WIN11_TEST_WSL_PATH', 'Process') }
                $items = @(Get-WslDistributions)
                if ($items.Count -ne 2 -or
                    @($items | Where-Object { $_.Name -eq 'Ubuntu-24.04' -and $_.Version -eq 2 }).Count -ne 1 -or
                    @($items | Where-Object { $_.Name -eq 'Ubuntu-22.04' -and $_.Version -eq 1 }).Count -ne 1) {
                    throw 'WSL verbose distribution versions were not parsed correctly.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $null, 'Process')
        }
    }

    It 'adds web-download only to the proxied WSL install retry' {
        $fakeWsl = Join-Path $TestDrive 'record-wsl.cmd'
        $record = Join-Path $TestDrive 'wsl-arguments.txt'
        @'
@echo off
echo %* > "%WIN11_TEST_WSL_ARGUMENTS%"
exit /b 0
'@ | Set-Content -LiteralPath $fakeWsl -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $fakeWsl, 'Process')
        [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_ARGUMENTS', $record, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Get-TrustedSystemExecutablePath { [Environment]::GetEnvironmentVariable('WIN11_TEST_WSL_PATH', 'Process') }
                $result = Invoke-WslInstallCommand -Distribution 'Ubuntu-24.04' -ProxyUri 'http://127.0.0.1:7897'
                $recordPath = [Environment]::GetEnvironmentVariable('WIN11_TEST_WSL_ARGUMENTS', 'Process')
                $arguments = Get-Content -LiteralPath $recordPath -Raw
                if ($result.ExitCode -ne 0 -or $arguments -notmatch '(?:^|\s)--web-download(?:\s|$)') {
                    throw 'The proxied WSL retry did not use --web-download.'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_ARGUMENTS', $null, 'Process')
        }
    }

    It 'distinguishes a missing wsl.exe from trusted path or signature failure' {
        InModuleScope Win11Bootstrap {
            Mock Get-TrustedSystemExecutablePath { throw [System.IO.FileNotFoundException]::new('missing') }
            $missing = Invoke-WslInstallCommand -Distribution 'Ubuntu-24.04'
            if ($missing.ExitCode -ne 126 -or $missing.SecurityFailure) {
                throw 'A missing wsl.exe was not treated as an ordinary unavailable-command failure.'
            }

            Mock Get-TrustedSystemExecutablePath { throw [System.Security.SecurityException]::new('invalid signature') }
            $unsafe = Invoke-WslInstallCommand -Distribution 'Ubuntu-24.04'
            if ($unsafe.ExitCode -ne 126 -or -not $unsafe.SecurityFailure) {
                throw 'A trusted path or signature rejection was not marked as a WSL security failure.'
            }
        }
    }

    It 'maps WSL command trust failure to NonCompliant without proxy retry' {
        $fakeWsl = Join-Path $TestDrive 'trusted-wsl.cmd'
        "@echo off`r`nexit /b 0" | Set-Content -LiteralPath $fakeWsl -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $fakeWsl, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
                Mock Get-WslDistributions { @() }
                Mock Get-TrustedSystemExecutablePath { [Environment]::GetEnvironmentVariable('WIN11_TEST_WSL_PATH', 'Process') }
                Mock Invoke-WslInstallCommand { [pscustomobject]@{ ExitCode = 126; Output = 'invalid signature'; SecurityFailure = $true } }
                Mock Get-ProxyCandidates { throw 'A WSL security failure must not trigger proxy retry.' }
                $application = [pscustomobject]@{
                    WindowsFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
                    Detection = @{ WslDistribution = 'Ubuntu-24.04' }
                }

                $result = Install-WslApplication -Application $application
                if ($result.Success -or $result.FailureKind -ne 'NonCompliant') {
                    throw 'A WSL trusted-command failure did not map to NonCompliant.'
                }
                Assert-MockCalled Get-ProxyCandidates -Times 0 -Scope It
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $null, 'Process')
        }
    }

    It 'maps set-default trusted-command rejection to NonCompliant' {
        InModuleScope Win11Bootstrap {
            Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
            Mock Get-WslDistributions { @() }
            Mock Get-TrustedSystemExecutablePath { throw [System.Security.SecurityException]::new('invalid signature') }
            Mock Invoke-WslInstallCommand { throw 'Install must not run after a set-default trust rejection.' }
            $application = [pscustomobject]@{
                WindowsFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
                Detection = @{ WslDistribution = 'Ubuntu-24.04' }
            }

            $result = Install-WslApplication -Application $application
            if ($result.Success -or $result.FailureKind -ne 'NonCompliant') {
                throw 'A set-default trusted-command rejection did not map to NonCompliant.'
            }
            Assert-MockCalled Invoke-WslInstallCommand -Times 0 -Scope It
        }
    }

    It 'stops when WSL cannot set version 2 as the default' {
        $fakeWsl = Join-Path $TestDrive 'failing-wsl.cmd'
        @'
@echo off
echo simulated set-default failure
exit /b 5
'@ | Set-Content -LiteralPath $fakeWsl -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $fakeWsl, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
                Mock Get-WslDistributions { @() }
                Mock Get-TrustedSystemExecutablePath { [Environment]::GetEnvironmentVariable('WIN11_TEST_WSL_PATH', 'Process') }
                Mock Invoke-WslInstallCommand { throw 'Install must not run after set-default failure.' }
                $application = [pscustomobject]@{
                    WindowsFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
                    Detection = @{ WslDistribution = 'Ubuntu-24.04' }
                }
                $result = Install-WslApplication -Application $application
                if ($result.FailureKind -ne 'Failed') {
                    throw 'A failed wsl.exe --set-default-version command was ignored.'
                }
                Assert-MockCalled Invoke-WslInstallCommand -Times 0 -Scope It
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_WSL_PATH', $null, 'Process')
        }
    }

    It 'does not treat the system wsl.exe command as an installed distribution' {
        InModuleScope Win11Bootstrap {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\wsl.exe' } }
            Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
            Mock Get-WslDistributions { @() }
            Mock Get-Service { @() }
            $catalog = Import-AppCatalog
            $application = @($catalog.Applications | Where-Object { $_.Key -eq 'wsl2-ubuntu' })[0]
            $result = Test-AppInstalled -Application $application -UninstallEntries @()
            if ($result.Installed) {
                throw 'wsl.exe alone incorrectly satisfied the WSL 2 Ubuntu contract.'
            }
        }
    }

    It 'detects an existing WSL 2 distribution in WhatIf without feature elevation' {
        InModuleScope Win11Bootstrap {
            Mock Get-WslDistributions { @([pscustomobject]@{ Name = 'Ubuntu-24.04'; State = 'Stopped'; Version = 2 }) }
            Mock Get-WindowsOptionalFeature { throw 'ERROR_ELEVATION_REQUIRED' }
            Mock Get-Command { $null }
            Mock Get-Service { @() }
            $catalog = Import-AppCatalog
            $application = @($catalog.Applications | Where-Object { $_.Key -eq 'wsl2-ubuntu' })[0]
            $result = Test-AppInstalled -Application $application -UninstallEntries @() -DryRun
            if (-not $result.Installed -or $result.NonCompliant) {
                throw 'An existing VERSION 2 distribution was not detected during non-elevated WhatIf.'
            }
            Assert-MockCalled Get-WindowsOptionalFeature -Times 0 -Scope It
        }
    }

    It 'does not invoke WinGet CLI detection during dry-run' {
        InModuleScope Win11Bootstrap {
            Mock Get-WingetCommandPath { throw 'WinGet CLI must not run during dry-run detection.' }
            $application = [pscustomobject]@{
                Key = 'dry-run-test'
                InstallerType = 'Winget'
                WingetId = 'Example.DryRun'
                Detection = @{}
                VersionPolicy = @{}
            }
            $result = Test-AppInstalled -Application $application -UninstallEntries @() -DryRun
            if ($result.Installed) {
                throw 'Dry-run produced false WinGet installation evidence.'
            }
            Assert-MockCalled Get-WingetCommandPath -Times 0 -Scope It
        }
    }

    It 'rejects a reparse-point seed before copying it into staging' {
        $seedDirectory = Join-Path $TestDrive 'seed'
        $stageDirectory = Join-Path $TestDrive 'stage'
        [void](New-Item -ItemType Directory -Path $seedDirectory)
        [void](New-Item -ItemType Directory -Path $stageDirectory)
        'seed' | Set-Content -LiteralPath (Join-Path $seedDirectory 'setup.exe') -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_SEED', $seedDirectory, 'Process')
        [Environment]::SetEnvironmentVariable('WIN11_TEST_STAGE', $stageDirectory, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $originalRemoveSecureStagingDirectory = ${function:Remove-SecureStagingDirectory}
                try {
                    Mock New-SecureStagingDirectory { [Environment]::GetEnvironmentVariable('WIN11_TEST_STAGE', 'Process') }
                    Set-Item -LiteralPath Function:\Remove-SecureStagingDirectory -Value { param($Path) }
                    Mock Get-Item {
                        [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint; FullName = 'reparse-seed' }
                    }
                    $result = Get-VerifiedInstallerFile -Metadata @{
                        FileName = 'setup.exe'
                        Sha256 = ('A' * 64)
                        SignerSubject = 'CN=Trusted Publisher, O=Example'
                    } -SeedDirectory ([Environment]::GetEnvironmentVariable('WIN11_TEST_SEED', 'Process')) -Catalog @{}
                    if ($result.FailureKind -ne 'NonCompliant') {
                        throw 'A reparse-point seed was not rejected before copying.'
                    }
                }
                finally {
                    Set-Item -LiteralPath Function:\Remove-SecureStagingDirectory -Value $originalRemoveSecureStagingDirectory
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_SEED', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WIN11_TEST_STAGE', $null, 'Process')
        }
    }

    It 'refuses staging cleanup when any descendant is a reparse point' {
        $tree = Join-Path $TestDrive 'cleanup-tree'
        $target = Join-Path $TestDrive 'cleanup-target'
        [void](New-Item -ItemType Directory -Path $tree -Force)
        [void](New-Item -ItemType Directory -Path $target -Force)
        'keep' | Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Encoding ascii
        [void](New-Item -ItemType Junction -Path (Join-Path $tree 'link') -Target $target)
        [Environment]::SetEnvironmentVariable('WIN11_TEST_CLEANUP_TREE', $tree, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $path = [Environment]::GetEnvironmentVariable('WIN11_TEST_CLEANUP_TREE', 'Process')
                $caught = $false
                try { [void](Assert-SecureRemovalTree -Path $path) }
                catch [System.Security.SecurityException] { $caught = $true }
                if (-not $caught) {
                    throw 'A descendant staging junction was not rejected before recursive cleanup.'
                }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) {
                throw 'The cleanup boundary followed a staging junction into its target.'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_CLEANUP_TREE', $null, 'Process')
        }
    }

    It 'throws a security failure before touching a cleanup path outside secure staging' {
        InModuleScope Win11Bootstrap {
            $outsidePath = Join-Path ([IO.Path]::GetTempPath()) 'win11-bootstrap-outside-cleanup'
            $caught = $false
            try { Remove-SecureStagingDirectory -Path $outsidePath }
            catch [System.Security.SecurityException] { $caught = $true }
            if (-not $caught) {
                throw 'A cleanup path outside secure staging was not rejected.'
            }
        }
    }

    It 'throws a security failure before touching a non-random staging leaf' {
        InModuleScope Win11Bootstrap {
            $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
            $invalidLeaf = Join-Path $programData 'Win11Bootstrap\Staging\not-a-random-guid'
            $caught = $false
            try { Remove-SecureStagingDirectory -Path $invalidLeaf }
            catch [System.Security.SecurityException] { $caught = $true }
            if (-not $caught) {
                throw 'A non-random staging cleanup leaf was not rejected.'
            }
        }
    }

    It 'maps post-install staging cleanup failure to NonCompliant without escaping the provider' {
        InModuleScope Win11Bootstrap {
            $originalAcquire = ${function:Get-VerifiedInstallerFile}
            Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value {
                param($Metadata, $SeedDirectory, $ExplicitProxyUri, $NoGitHubMirrors, $Catalog)
                [pscustomobject]@{ Success = $true; FailureKind = ''; Path = 'C:\ProgramData\Win11Bootstrap\Staging\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\setup.exe'; StageDirectory = 'C:\ProgramData\Win11Bootstrap\Staging\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; Detail = 'verified' }
            }
            try {
                Mock Test-SecureStagedFile { return $true }
                Mock Test-InstallerTrust { [pscustomobject]@{ Trusted = $true; Detail = 'verified' } }
                Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
                Mock Remove-SecureStagingDirectory { throw [System.Security.SecurityException]::new('simulated cleanup refusal') }

                $result = Install-DirectApplication -Application @{ Name = 'Test' } -Metadata @{
                    FileName = 'setup.exe'; Sha256 = ('A' * 64); SignerSubject = 'CN=Trusted Publisher, O=Example'; SilentArgs = @('/S')
                } -Catalog @{}
                if ($result.Success -or $result.FailureKind -ne 'NonCompliant') {
                    throw 'A successful installer incorrectly masked its staging cleanup security failure.'
                }
                Assert-MockCalled Start-Process -Times 1 -Scope It
                Assert-MockCalled Remove-SecureStagingDirectory -Times 1 -Scope It
            }
            finally { Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value $originalAcquire }
        }
    }

    It 'maps a trusted-executable security rejection to NonCompliant without starting the installer' {
        InModuleScope Win11Bootstrap {
            $originalAcquire = ${function:Get-VerifiedInstallerFile}
            Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value {
                param($Metadata, $SeedDirectory, $ExplicitProxyUri, $NoGitHubMirrors, $Catalog)
                [pscustomobject]@{ Success = $true; FailureKind = ''; Path = 'C:\ProgramData\Win11Bootstrap\Staging\cccccccccccccccccccccccccccccccc\setup.msi'; StageDirectory = 'C:\ProgramData\Win11Bootstrap\Staging\cccccccccccccccccccccccccccccccc'; Detail = 'verified' }
            }
            try {
                Mock Test-SecureStagedFile { return $true }
                Mock Get-TrustedSystemExecutablePath { throw [System.Security.SecurityException]::new('simulated untrusted msiexec') }
                Mock Start-Process { throw 'The installer must not start after a trusted-executable rejection.' }
                Mock Remove-SecureStagingDirectory { }

                $result = Install-DirectApplication -Application @{ Name = 'Test' } -Metadata @{
                    FileName = 'setup.msi'; Sha256 = ('C' * 64); SignerSubject = 'CN=Trusted Publisher, O=Example'; SilentArgs = @()
                } -Catalog @{}
                if ($result.Success -or $result.FailureKind -ne 'NonCompliant') {
                    throw 'A trusted-executable security rejection did not use the policy-conflict result.'
                }
                Assert-MockCalled Start-Process -Times 0 -Scope It
                Assert-MockCalled Remove-SecureStagingDirectory -Times 1 -Scope It
            }
            finally { Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value $originalAcquire }
        }
    }

    It 'preserves successful direct installation when secure staging cleanup succeeds' {
        InModuleScope Win11Bootstrap {
            $originalAcquire = ${function:Get-VerifiedInstallerFile}
            Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value {
                param($Metadata, $SeedDirectory, $ExplicitProxyUri, $NoGitHubMirrors, $Catalog)
                [pscustomobject]@{ Success = $true; FailureKind = ''; Path = 'C:\ProgramData\Win11Bootstrap\Staging\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\setup.exe'; StageDirectory = 'C:\ProgramData\Win11Bootstrap\Staging\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Detail = 'verified' }
            }
            try {
                Mock Test-SecureStagedFile { return $true }
                Mock Test-InstallerTrust { [pscustomobject]@{ Trusted = $true; Detail = 'verified' } }
                Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
                Mock Remove-SecureStagingDirectory { }

                $result = Install-DirectApplication -Application @{ Name = 'Test' } -Metadata @{
                    FileName = 'setup.exe'; Sha256 = ('B' * 64); SignerSubject = 'CN=Trusted Publisher, O=Example'; SilentArgs = @('/S')
                } -Catalog @{}
                if (-not $result.Success -or -not [string]::IsNullOrWhiteSpace([string]$result.FailureKind)) {
                    throw 'Successful secure staging cleanup changed the installer result.'
                }
                Assert-MockCalled Remove-SecureStagingDirectory -Times 1 -Scope It
            }
            finally { Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value $originalAcquire }
        }
    }

    It 'propagates cleanup policy failures through direct, seed, and Clash fallback paths' {
        InModuleScope Win11Bootstrap {
            Mock Get-DirectInstallerMetadata { return @{ FileName = 'setup.exe' } }
            $originalInstallDirect = ${function:Install-DirectApplication}
            Set-Item -LiteralPath Function:\Install-DirectApplication -Value {
                param($Application, $Metadata, $SeedDirectory, $ExplicitProxyUri, $NoGitHubMirrors, $Catalog)
                [pscustomobject]@{ Success = $false; FailureKind = 'NonCompliant'; Detail = 'secure cleanup failed' }
            }
            try {
                foreach ($type in @('Direct', 'ManualOrSeed')) {
                    $application = [pscustomobject]@{ Name = $type; InstallerType = $type; Safety = @{ Ready = $true } }
                    $result = Install-CatalogApplication -Application $application -Catalog @{}
                    if ($result.Status -ne 'NonCompliant') {
                        throw "$type did not preserve the staging cleanup policy failure."
                    }
                }

                $clashApplication = [pscustomobject]@{ Name = 'Clash'; Safety = @{ DirectFallbackReady = $true }; ManualActions = @() }
                $clashResult = [pscustomobject]@{ Application = $clashApplication; Status = 'Planned'; Detail = '' }
                if (Install-ClashFallback -ClashResult $clashResult -Catalog @{}) {
                    throw 'Clash fallback reported success after staging cleanup failed.'
                }
                if ($clashResult.Status -ne 'NonCompliant') {
                    throw 'Clash fallback did not preserve the staging cleanup policy failure.'
                }
            }
            finally {
                Set-Item -LiteralPath Function:\Install-DirectApplication -Value $originalInstallDirect
            }
        }
    }

    It 'fails closed and cleans staging when final installer trust changes' {
        $stage = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $stage)
        $file = Join-Path $stage 'setup.exe'
        'placeholder' | Set-Content -LiteralPath $file -Encoding ascii
        [Environment]::SetEnvironmentVariable('WIN11_TEST_STAGE', $stage, 'Process')
        [Environment]::SetEnvironmentVariable('WIN11_TEST_INSTALLER', $file, 'Process')
        try {
            InModuleScope Win11Bootstrap {
                $originalAcquire = ${function:Get-VerifiedInstallerFile}
                Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value {
                    param($Application, $Metadata, $SeedDirectory, $ExplicitProxyUri, $NoGitHubMirrors, $Catalog)
                    [pscustomobject]@{
                        Success = $true
                        FailureKind = ''
                        Path = [Environment]::GetEnvironmentVariable('WIN11_TEST_INSTALLER', 'Process')
                        StageDirectory = [Environment]::GetEnvironmentVariable('WIN11_TEST_STAGE', 'Process')
                        Detail = 'verified during acquisition'
                    }
                }
                try {
                    Mock Test-SecureStagedFile { $true }
                    Mock Test-InstallerTrust { [pscustomobject]@{ Trusted = $false; Detail = 'changed after acquisition' } }
                    Mock Remove-SecureStagingDirectory { }
                    Mock Start-Process { throw 'An untrusted installer must not execute.' }

                    $result = Install-DirectApplication -Application @{ Name = 'Test' } -Metadata @{
                        FileName = 'setup.exe'
                        Sha256 = ('A' * 64)
                        SignerSubject = 'CN=Trusted Publisher, O=Example'
                        SilentArgs = @('/S')
                    } -Catalog @{}
                    if ($result.FailureKind -ne 'NonCompliant') {
                        throw 'A final trust mismatch did not fail closed.'
                    }
                    Assert-MockCalled Start-Process -Times 0 -Scope It
                    Assert-MockCalled Remove-SecureStagingDirectory -Times 1 -Scope It
                }
                finally {
                    Set-Item -LiteralPath Function:\Get-VerifiedInstallerFile -Value $originalAcquire
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('WIN11_TEST_STAGE', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WIN11_TEST_INSTALLER', $null, 'Process')
        }
    }
}

Describe 'Protected major detection' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        Import-Module -Name (Join-Path $script:RepositoryRoot 'src\Win11Bootstrap.psm1') -Force
    }

    It 'reports RealVNC v8 as noncompliant without invoking an installer' {
        InModuleScope Win11Bootstrap {
            Mock Get-UninstallEntries {
                @([pscustomobject]@{
                    DisplayName = 'RealVNC Connect 8.2.2'
                    DisplayVersion = '8.2.2'
                    Publisher = 'RealVNC Limited'
                    InstallLocation = 'C:\Program Files\RealVNC'
                })
            }
            Mock Get-Command { $null }
            Mock Get-Service { @() }
            Mock Get-WingetCommandPath { $null }

            $catalog = Import-AppCatalog
            $application = @($catalog.Applications | Where-Object { $_.Key -eq 'realvnc-server' })[0]
            $result = Test-AppInstalled -Application $application
            if (-not $result.Installed -or -not $result.NonCompliant) {
                throw 'RealVNC v8 was not classified as installed and noncompliant.'
            }
        }
    }

    It 'blocks Viewer v8, NoMachine v10, prefixed, embedded, and unknown protected versions' {
        InModuleScope Win11Bootstrap {
            Mock Get-Command { $null }
            Mock Get-Service { @() }
            Mock Get-AppxPackage { @() }
            Mock Get-WingetCommandPath { $null }
            $catalog = Import-AppCatalog
            $viewer = @($catalog.Applications | Where-Object { $_.Key -eq 'realvnc-viewer' })[0]
            $server = @($catalog.Applications | Where-Object { $_.Key -eq 'realvnc-server' })[0]
            $noMachine = @($catalog.Applications | Where-Object { $_.Key -eq 'nomachine' })[0]

            $cases = @(
                @{ App = $viewer; Entry = [pscustomobject]@{ DisplayName = 'RealVNC Viewer 8.1'; DisplayVersion = '8.1'; Publisher = 'RealVNC Limited' }; Label = 'Viewer v8' },
                @{ App = $noMachine; Entry = [pscustomobject]@{ DisplayName = 'NoMachine 10'; DisplayVersion = '10.0'; Publisher = 'NoMachine S.a.r.l.' }; Label = 'NoMachine v10' },
                @{ App = $server; Entry = [pscustomobject]@{ DisplayName = 'RealVNC Server'; DisplayVersion = 'v8.2'; Publisher = 'RealVNC Limited' }; Label = 'v8 prefix' },
                @{ App = $server; Entry = [pscustomobject]@{ DisplayName = 'RealVNC Server 8.3'; DisplayVersion = ''; Publisher = 'RealVNC Limited' }; Label = 'embedded version' },
                @{ App = $server; Entry = [pscustomobject]@{ DisplayName = 'RealVNC Server'; DisplayVersion = ''; Publisher = 'RealVNC Limited' }; Label = 'unknown version' }
            )
            foreach ($case in $cases) {
                $result = Test-AppInstalled -Application $case.App -UninstallEntries @($case.Entry)
                if (-not $result.Installed -or -not $result.NonCompliant) {
                    throw ("Protected-major case '{0}' was not fail-closed." -f $case.Label)
                }
            }

            $mixed = Test-AppInstalled -Application $server -UninstallEntries @(
                [pscustomobject]@{ DisplayName = 'RealVNC Server 7'; DisplayVersion = '7.18.0'; Publisher = 'RealVNC Limited' },
                [pscustomobject]@{ DisplayName = 'RealVNC Server'; DisplayVersion = ''; Publisher = 'RealVNC Limited' }
            )
            if (-not $mixed.Installed -or -not $mixed.NonCompliant) {
                throw 'Known protected v7 evidence incorrectly masked a second unknown-major instance.'
            }
        }
    }


    It 'restores every process proxy setting when an operation throws' {
        InModuleScope Win11Bootstrap {
            $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
            $original = @{}
            foreach ($name in $names) {
                $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, "sentinel-$name", 'Process')
            }
            $expected = @{}
            foreach ($name in $names) {
                $expected[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            $originalDefaultProxy = [Net.WebRequest]::DefaultWebProxy
            try {
                try {
                    Invoke-WithProcessProxy -ProxyUri 'http://127.0.0.1:7897' -ScriptBlock { throw 'expected test failure' }
                }
                catch { Write-Debug 'Expected process proxy failure observed.' }

                foreach ($name in $names) {
                    $actual = [Environment]::GetEnvironmentVariable($name, 'Process')
                    if ($actual -cne $expected[$name]) {
                        throw "Process proxy variable $name was not restored."
                    }
                }
                if (-not [object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy, $originalDefaultProxy)) {
                    throw 'DefaultWebProxy was not restored.'
                }
            }
            finally {
                [Net.WebRequest]::DefaultWebProxy = $originalDefaultProxy
                foreach ($name in $names) {
                    [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
                }
            }
        }
    }

    It 'rejects proxy credentials at validation and candidate boundaries' {
        InModuleScope Win11Bootstrap {
            $rejected = $false
            try { [void](Resolve-ProxyUriValue -Value 'http://user:secret@127.0.0.1:7897') } catch { $rejected = $true }
            if (-not $rejected) {
                throw 'Credentialed proxy validation did not throw.'
            }
            $queryRejected = $false
            try { [void](Resolve-ProxyUriValue -Value 'http://127.0.0.1:7897/?token=secret') } catch { $queryRejected = $true }
            if (-not $queryRejected) {
                throw 'A proxy URI carrying a query secret was not rejected before elevation.'
            }
            if (Test-ProxyUri -ProxyUri 'http://user:secret@127.0.0.1:7897') {
                throw 'Credentialed proxy passed the HTTPS probe boundary.'
            }
            if (@(Get-ProxyCandidates -ExplicitProxyUri 'http://user:secret@127.0.0.1:7897') -contains 'http://user:secret@127.0.0.1:7897/') {
                throw 'A credentialed proxy entered the candidate list.'
            }
        }
    }
}
