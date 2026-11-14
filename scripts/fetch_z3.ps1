# Fetch the prebuilt Z3 5.3.3 x64 C SDK binaries into lib/.
#
# The repository only tracks Z3 headers and license; the large DLL/LIB files are
# intentionally excluded from Git. Run this script after cloning (or when libz3.dll
# is missing). Requires network access to GitHub releases.

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $root 'lib'
$version = '5.3.3'
$url = "https://github.com/Z3Prover/z3/releases/download/z3-$version/z3-$version-x64-win.zip"
$expectedSha256 = '4E48624A6895B49606B3CF91CA4FBCC069FB2973B9706532170A144BAA3FD798'

if (-not (Test-Path $lib)) {
    New-Item -ItemType Directory -Path $lib | Out-Null
}

$dll = Join-Path $lib 'libz3.dll'
if ((Test-Path $dll) -and -not $Force) {
    Write-Host "libz3.dll already exists; use -Force to re-download."
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("z3-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tmp "z3-$version-x64-win.zip"
$extract = Join-Path $tmp 'extract'
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    Write-Host "Downloading $url"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -L --fail --retry 4 --retry-all-errors -o $zip $url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }

    $sha = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($sha -ne $expectedSha256) {
        throw "SHA256 mismatch: got $sha, expected $expectedSha256"
    }

    Write-Host "Extracting"
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $src = Join-Path $extract "z3-$version-x64-win"
    if (-not (Test-Path $src)) { throw "unexpected archive layout: $src not found" }

    Copy-Item (Join-Path $src 'bin\libz3.dll') $lib -Force
    Copy-Item (Join-Path $src 'bin\libz3.lib') $lib -Force
    Copy-Item (Join-Path $src 'LICENSE.txt') (Join-Path $lib 'LICENSE.txt') -Force

    $includeDir = Join-Path $lib 'include'
    if (-not (Test-Path $includeDir)) { New-Item -ItemType Directory -Path $includeDir | Out-Null }
    Copy-Item (Join-Path $src 'include\*.h') $includeDir -Force

    foreach ($pattern in @('msvcp140*.dll', 'vcruntime140*.dll', 'vcomp140.dll')) {
        Get-ChildItem (Join-Path $src 'bin') -Filter $pattern -File -ErrorAction SilentlyContinue |
            Copy-Item -Destination $lib -Force
    }

    Write-Host "Done: Z3 $version binaries installed into $lib"
    Write-Host "Run build.bat (or build.sh) so the DLLs are copied next to the executable."
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
