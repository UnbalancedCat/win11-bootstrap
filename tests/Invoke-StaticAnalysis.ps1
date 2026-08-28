#requires -Version 5.1
#requires -Modules @{ ModuleName = 'PSScriptAnalyzer'; RequiredVersion = '1.24.0' }

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$settingsPath = Join-Path -Path $repositoryRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$issues = New-Object 'System.Collections.Generic.List[object]'

$productionPaths = @(
    'bootstrap.ps1'
    'src'
    'catalog'
    'tests\Get-RuntimeFingerprint.ps1'
    'tests\New-ReleaseBundle.ps1'
    'tests\Invoke-StaticAnalysis.ps1'
    'tests\Validate-Repository.ps1'
    'tests\acceptance'
)

foreach ($relativePath in $productionPaths) {
    $path = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    $arguments = @{
        Path = $path
        Settings = $settingsPath
        Severity = @('Warning', 'Error')
    }
    if (Test-Path -LiteralPath $path -PathType Container) {
        $arguments['Recurse'] = $true
    }
    foreach ($issue in @(Invoke-ScriptAnalyzer @arguments)) {
        [void]$issues.Add($issue)
    }
}

# Pester mocks intentionally accept the production command signature even
# when a particular test does not consume every argument. Keep the unused
# parameter exception confined to *.Tests.ps1 rather than hiding it in src/.
foreach ($testFile in @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.Tests.ps1')) {
    foreach ($issue in @(Invoke-ScriptAnalyzer `
        -Path $testFile.FullName `
        -Settings $settingsPath `
        -Severity Warning,Error `
        -ExcludeRule PSReviewUnusedParameter)) {
        [void]$issues.Add($issue)
    }
}

if ($issues.Count -gt 0) {
    $issues |
        Sort-Object ScriptName, Line, RuleName |
        Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize |
        Out-String |
        Write-Output
    throw "PSScriptAnalyzer reported $($issues.Count) issue(s)."
}

Write-Output 'PSScriptAnalyzer validation passed.'
