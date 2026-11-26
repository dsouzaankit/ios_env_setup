# PC-side signing with SideStore's exported certificate + zsign, shared by the sideloaded app repos that
# sit next to env_setup (Loop Segments wraps it in windows\lib\Get-LoopSegmentsSigning.ps1). Dot-source it.
# See README.md in this folder.
#
# Everything lives in this folder: zsign.exe (downloaded, gitignored), signing.p12 (SideStore's export,
# gitignored; it syncs with this folder, e.g. on pCloud), and sidestore_sign.py (check / sign-install).
# The .p12 password is per PC, in Windows Credential Manager, never in a file.

$SideStoreZsignDir = $PSScriptRoot
$SideStoreSigningP12 = Join-Path $PSScriptRoot 'signing.p12'
$SideStoreSignPy = Join-Path $PSScriptRoot 'sidestore_sign.py'

# Generic credential holding the .p12 password. Older setups saved it as LoopSegments-signing: still found.
$SideStoreSigningCredTarget = 'SideStore-signing'
$SideStoreSigningLegacyCredTargets = @('LoopSegments-signing')

# zsign release Install-SideStoreZsign downloads (hash from the release's SHA256SUMS.txt).
$SideStoreZsignVersion = 'v1.1.3'
$SideStoreZsignZipSha256 = '6fb5e12a5b7179cfe7e729aa471b35ccf86474eba33d8203df119bf62bad77f7'

function Find-SideStoreZsign {
    # -Override first (an app's own config), then zsign.exe in this folder, then PATH. $null if none.
    param([string] $Override = '')
    $list = @()
    if ($Override.Trim()) { $list += $Override.Trim() }
    $list += (Join-Path $SideStoreZsignDir 'zsign.exe')
    foreach ($p in $list) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    $c = Get-Command zsign -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Install-SideStoreZsign {
    # Downloads the pinned zsign-windows-x64.zip from github.com/zhlynn/zsign, checks its SHA-256, and
    # unzips it into this folder. Returns zsign.exe's path; throws on a download or hash failure.
    $url = "https://github.com/zhlynn/zsign/releases/download/$SideStoreZsignVersion/zsign-windows-x64.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("zsign-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'zsign-windows-x64.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $SideStoreZsignZipSha256) { throw "zsign download hash mismatch ($hash); not installed." }
        Expand-Archive -LiteralPath $zip -DestinationPath $SideStoreZsignDir -Force
        $exe = Join-Path $SideStoreZsignDir 'zsign.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "zsign.exe not found in $SideStoreZsignDir after unzipping." }
        return $exe
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-SideStoreSigningPassword {
    param([string] $CredTarget = $SideStoreSigningCredTarget)
    return [bool]((& cmdkey /list 2>$null) | Select-String -SimpleMatch "target=$CredTarget")
}

function Resolve-SideStoreSigningCredTarget {
    # The credential this PC has: SideStore-signing, else a legacy name, else SideStore-signing (to create).
    foreach ($t in @($SideStoreSigningCredTarget) + $SideStoreSigningLegacyCredTargets) {
        if (Test-SideStoreSigningPassword -CredTarget $t) { return $t }
    }
    return $SideStoreSigningCredTarget
}

function Set-SideStoreSigningPassword {
    # cmdkey prompts itself, so the password is never on a command line or in history.
    param([string] $CredTarget = $SideStoreSigningCredTarget)
    & cmdkey "/generic:$CredTarget" '/user:p12' '/pass'
    return (Test-SideStoreSigningPassword -CredTarget $CredTarget)
}

function Copy-SideStoreSigningP12 {
    # Puts a SideStore export at signing.p12 in this folder (replaces the one there).
    param([Parameter(Mandatory)] [string] $Source)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "No file at $Source" }
    Copy-Item -LiteralPath $Source -Destination $SideStoreSigningP12 -Force
    return $SideStoreSigningP12
}
