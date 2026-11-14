# Acceptance runner for OOMap (原始任务规格 section 11).
# 1. odin test src                -> format / infeasible / boundaries / wrap-around / frozen
# 2. encoder --check-pure         -> roundtrip (5/20/64/65/1000) and 1000-entry performance
# 3. encoder --check-z3           -> family 3 minimal |p| and 100ms timeout
# 4. encoder --check-missing-z3   -> degradation after hiding libz3.dll

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
$failed = @()

function Step($name, $scriptBlock) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    try {
        & $scriptBlock
        if ($LASTEXITCODE -ne 0) {
            throw "exit code $LASTEXITCODE"
        }
        Write-Host "PASS: $name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL: $name ($_)" -ForegroundColor Red
        $script:failed += $name
    }
}

try {
    Step 'build' {
        if (-not (Get-Command odin -ErrorAction SilentlyContinue)) { throw 'odin not found in PATH' }
        & odin build src -out:bin\OOMap.exe
        if (Test-Path lib\*.dll) { Copy-Item lib\*.dll bin\ -Force }
    }

    Step 'odin test src' {
        & odin test src
    }

    Step 'roundtrip + performance (--check-pure)' {
        & .\bin\OOMap.exe --check-pure
    }

    Step 'family 3 + timeout (--check-z3)' {
        & .\bin\OOMap.exe --check-z3
    }

    Step 'CSV end-to-end (--test-csv)' {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if ($python) {
            & python scripts\gen_test_csv.py
            if ($LASTEXITCODE -ne 0) { throw "gen_test_csv.py exit code $LASTEXITCODE" }
        } else {
            Write-Host "python not found; using existing bin\test.csv if present"
        }
        & .\bin\OOMap.exe --test-csv
    }

    Step 'missing Z3 (--check-missing-z3)' {
        $candidates = @(
            (Join-Path $root 'lib\libz3.dll'),
            (Join-Path $root 'bin\libz3.dll')
        ) | Where-Object { Test-Path $_ }
        if ($candidates.Count -eq 0) { throw 'libz3.dll not found' }
        $hidden = @()
        try {
            foreach ($dll in $candidates) {
                Rename-Item $dll "$dll.hidden"
                $hidden += $dll
            }
            & .\bin\OOMap.exe --check-missing-z3
        } finally {
            foreach ($dll in $hidden) {
                Rename-Item "$dll.hidden" $dll
            }
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL ACCEPTANCE CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILED: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}

