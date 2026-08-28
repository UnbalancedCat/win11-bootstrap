#requires -Version 5.1
[CmdletBinding()]
param([Parameter()][string]$ModulePath = (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'src\Win11Bootstrap.psm1'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force

$source = Join-Path $env:SystemRoot 'System32\notepad.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'A signed Windows fixture is unavailable.' }
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('w11b-trust-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryDirectory)
$fixture = Join-Path $temporaryDirectory 'signed-fixture.exe'
try {
    Copy-Item -LiteralPath $source -Destination $fixture
    $hash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    $signature = Get-AuthenticodeSignature -LiteralPath $fixture
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { throw 'The Windows fixture does not have a valid Authenticode signature.' }

    $hashMismatch = Test-InstallerTrust -Path $fixture -ExpectedSha256 ('0' * 64) -ExpectedSignerSubject $signature.SignerCertificate.Subject
    $signerMismatch = Test-InstallerTrust -Path $fixture -ExpectedSha256 $hash -ExpectedSignerSubject 'CN=Acceptance Fixture Wrong Publisher'
    if ($hashMismatch.Trusted -or $signerMismatch.Trusted) { throw 'The production trust boundary accepted an invalid fixture.' }
    $results = @(
        [pscustomobject]@{ Name = 'sha256-mismatch'; Status = 'NonCompliant'; ExitCode = 30; Executed = $false; Detail = $hashMismatch.Detail }
        [pscustomobject]@{ Name = 'publisher-mismatch'; Status = 'NonCompliant'; ExitCode = 30; Executed = $false; Detail = $signerMismatch.Detail }
    )
    $aggregate = Get-ExitCodeForResults -Results $results
    if ($aggregate -ne 30) { throw "Unexpected aggregate exit code: $aggregate" }
    [pscustomobject]@{ ExitCode = $aggregate; Results = $results }
    exit $aggregate
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) { [IO.Directory]::Delete($temporaryDirectory, $true) }
}
