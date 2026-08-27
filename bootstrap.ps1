#requires -Version 5.1

$entryScriptPath = $PSCommandPath
$entryScriptRoot = $PSScriptRoot
$entryArguments = @($args)
$entryPoint = {
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

    # This parameter is used only by the one-time UAC relaunch. Its value is a
    # random lookup key, never the serialized options.
    [Parameter(DontShow = $true)]
    [string]$ElevatedPayloadId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $entryScriptRoot -ChildPath 'src\Win11Bootstrap.psm1'

try {
# Prevent user-writable PSModulePath entries from shadowing PackageManagement,
# PowerShellGet, or repair commands used later in the elevated process. The
# repository module itself is imported by absolute path below. This process
# always exits, so the restriction cannot persist beyond this invocation.
$trustedModulePaths = New-Object System.Collections.Generic.List[string]
$psHomeModules = Join-Path $PSHOME 'Modules'
if (Test-Path -LiteralPath $psHomeModules -PathType Container) {
    [void]$trustedModulePaths.Add((Get-Item -LiteralPath $psHomeModules -Force -ErrorAction Stop).FullName)
}
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
    $allUsersModules = Join-Path $programFiles 'WindowsPowerShell\Modules'
    if (Test-Path -LiteralPath $allUsersModules -PathType Container) {
        [void]$trustedModulePaths.Add((Get-Item -LiteralPath $allUsersModules -Force -ErrorAction Stop).FullName)
    }
}
if ($trustedModulePaths.Count -eq 0) {
    throw 'No trusted PowerShell module root could be resolved.'
}
$env:PSModulePath = @($trustedModulePaths | Select-Object -Unique) -join [IO.Path]::PathSeparator

    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Core module was not found: $modulePath"
    }

    Microsoft.PowerShell.Core\Import-Module -Name $modulePath -Force -ErrorAction Stop

    $invokeArguments = @{}
    foreach ($name in @('Config', 'Only', 'Skip', 'Yes', 'ProxyUri', 'SeedDirectory', 'NoGitHubMirrors')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $invokeArguments[$name] = $PSBoundParameters[$name]
        }
    }

    if ($ElevatedPayloadId) {
        $payloadArguments = Get-BootstrapElevationPayload -Id $ElevatedPayloadId
        foreach ($entry in $payloadArguments.GetEnumerator()) {
            $invokeArguments[$entry.Key] = $entry.Value
        }
        $invokeArguments['ElevationAttempted'] = $true
    }

    $invokeArguments['ScriptPath'] = $entryScriptPath
    $invokeArguments['DryRun'] = [bool]$WhatIfPreference

    $exitCode = Invoke-Win11Bootstrap @invokeArguments
    if ($null -eq $exitCode) {
        $exitCode = 20
    }
    return ([int]$exitCode)
}
catch [System.Management.Automation.ParameterBindingException] {
    [Console]::Error.WriteLine("Parameter error: {0}" -f $_.Exception.Message)
    return 64
}
catch [System.Security.SecurityException] {
    [Console]::Error.WriteLine("Bootstrap security policy failure: {0}" -f $_.Exception.Message)
    return 30
}
catch {
    [Console]::Error.WriteLine("Bootstrap failed: {0}" -f $_.Exception.Message)
    return 20
}
}

try {
    $entryOutput = @(& $entryPoint @entryArguments)
    if ($entryOutput.Count -eq 0) {
        exit 20
    }
    exit ([int]$entryOutput[-1])
}
catch [System.Management.Automation.ParameterBindingException] {
    [Console]::Error.WriteLine("Parameter error: {0}" -f $_.Exception.Message)
    exit 64
}
catch [System.Security.SecurityException] {
    [Console]::Error.WriteLine("Bootstrap security policy failure: {0}" -f $_.Exception.Message)
    exit 30
}
catch {
    [Console]::Error.WriteLine("Bootstrap failed: {0}" -f $_.Exception.Message)
    exit 20
}
