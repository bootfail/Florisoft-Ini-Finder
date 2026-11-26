<#
  Florisoft Ini Finder
  Zoekt op een Florisoft-machine waar de client-instellingen staan en leest ze uit.

  - FS-INTRO.INI = FS_INTRO.DBF (of "fs_intro - <host> - <map>.dbf") naast Florisoft.exe / in de werkmap
    van de snelkoppeling. Bevat o.a. DIRECTORIES/DataDirectory.
  - Per gebruiker: <DataDirectory>\Ini\<USERID>\FS_2000.DBF, FS_SETUP.DBF, ...
  - Postgres-installaties: geen Ini-map; instellingen staan in tabel ini.fsini.

  Gebruik (PowerShell, geen admin nodig; admin ziet meer):
    [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/bootfail/Florisoft-Ini-Finder/main/Find-FlorisoftIni.ps1 | iex

  Met opties:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/bootfail/Florisoft-Ini-Finder/main/Find-FlorisoftIni.ps1))) -Export
    -Path <map>     extra map om te doorzoeken (bijv. installatiemap of netwerkshare)
    -Deep           alle vaste schijven volledig doorzoeken naar fs_intro*.dbf
    -Export         alle gebruikers-ini's naar CSV + zip
    -User <USERID>  alleen deze gebruiker exporteren (impliceert -Export)
    -ShowSecrets    wachtwoorden/sleutels niet verbergen
    -Quiet          geen inhoud van FS_INTRO op scherm, alleen in rapport
#>
param(
    [string]$Path,
    [switch]$Deep,
    [switch]$Export,
    [string]$User,
    [switch]$ShowSecrets,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$enc1252 = [Text.Encoding]::GetEncoding(1252)
$report = New-Object 'System.Collections.Generic.List[string]'
$secretPattern = 'PASS|WACHTW|PWD|SECRET|TOKEN|APIKEY|API_KEY|CLIENTKEY|PRIVATE|CONNECTIONSTRING|CONNSTR|LICENTIE'
if ($User) { $Export = $true }

function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray', [switch]$ReportOnly)
    if (-not $ReportOnly) { Write-Host $Text -ForegroundColor $Color }
    [void]$report.Add($Text)
}

function Protect-Value {
    param([string]$Sectie, [string]$Item, [string]$Waarde)
    if (-not $ShowSecrets -and ("$Sectie/$Item" -match $secretPattern)) {
        if ([string]::IsNullOrWhiteSpace($Waarde)) { return '<verborgen: leeg>' }
        return '<verborgen: gevuld>'
    }
    return $Waarde
}

function Read-Dbf {
    # Leest een dBase/FoxPro DBF (ook terwijl Florisoft/ADS hem open heeft) incl. .FPT-memo's.
    param([string]$File)
    $fs = New-Object IO.FileStream($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $mfs = $null
    try {
        $br = New-Object IO.BinaryReader($fs)
        $hdr = $br.ReadBytes(32)
        $count = [BitConverter]::ToUInt32($hdr, 4)
        $hlen = [BitConverter]::ToUInt16($hdr, 8)
        $rlen = [BitConverter]::ToUInt16($hdr, 10)
        $fields = New-Object 'System.Collections.Generic.List[object]'
        $offset = 1
        while ($fs.Position + 32 -le $hlen) {
            $fd = $br.ReadBytes(32)
            if ($fd[0] -eq 0x0D) { break }
            $name = $enc1252.GetString($fd, 0, 11).Split([char]0)[0].Trim()
            $fields.Add([pscustomobject]@{ Name = $name; Type = [string][char]$fd[11]; Length = [int]$fd[16]; Offset = $offset })
            $offset += [int]$fd[16]
        }

        $blockSize = 0; $memoKind = ''
        if ($fields | Where-Object { 'M', 'G', 'B' -contains $_.Type }) {
            foreach ($ext in '.FPT', '.DBT') {
                $mf = [IO.Path]::ChangeExtension($File, $ext)
                if (Test-Path -LiteralPath $mf) {
                    $mfs = New-Object IO.FileStream($mf, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    $mh = New-Object byte[] 8
                    [void]$mfs.Read($mh, 0, 8)
                    if ($ext -eq '.FPT') { $blockSize = $mh[6] * 256 + $mh[7]; $memoKind = 'FPT' } else { $blockSize = 512; $memoKind = 'DBT' }
                    if ($blockSize -le 0) { $blockSize = 64 }
                    break
                }
            }
        }

        $rows = New-Object 'System.Collections.Generic.List[object]'
        $fs.Position = $hlen
        for ($i = 0; $i -lt $count; $i++) {
            $rec = $br.ReadBytes($rlen)
            if ($rec.Length -lt $rlen) { break }
            if ($rec[0] -eq 0x2A) { continue }   # verwijderd record
            $o = [ordered]@{}
            foreach ($f in $fields) {
                if ($f.Offset + $f.Length -gt $rec.Length) { continue }
                $val = ''
                if ('M', 'G', 'B' -contains $f.Type) {
                    $blk = 0
                    if ($f.Length -eq 4) { $blk = [BitConverter]::ToInt32($rec, $f.Offset) }
                    else { [void][int]::TryParse($enc1252.GetString($rec, $f.Offset, $f.Length).Trim(), [ref]$blk) }
                    if ($blk -gt 0 -and $mfs) {
                        $mfs.Position = [int64]$blk * $blockSize
                        if ($memoKind -eq 'FPT') {
                            $mb = New-Object byte[] 8
                            [void]$mfs.Read($mb, 0, 8)
                            $len = [int64]$mb[4] * 16777216 + [int64]$mb[5] * 65536 + [int64]$mb[6] * 256 + [int64]$mb[7]
                            if ($len -gt 0 -and $len -lt 10MB) {
                                $data = New-Object byte[] $len
                                [void]$mfs.Read($data, 0, [int]$len)
                                $val = $enc1252.GetString($data)
                            }
                        } else {
                            $buf = New-Object 'System.Collections.Generic.List[byte]'
                            while ($buf.Count -lt 1MB) { $b = $mfs.ReadByte(); if ($b -lt 0 -or $b -eq 0x1A) { break }; $buf.Add([byte]$b) }
                            $val = $enc1252.GetString($buf.ToArray())
                        }
                    }
                } else {
                    $val = $enc1252.GetString($rec, $f.Offset, $f.Length)
                }
                $o[$f.Name] = $val.TrimEnd([char]0, ' ')
            }
            $rows.Add([pscustomobject]$o)
        }
        return [pscustomobject]@{ Fields = $fields; Rows = $rows }
    } finally {
        if ($mfs) { $mfs.Dispose() }
        $fs.Dispose()
    }
}

function Get-IniRows {
    # Geeft SECTIE/ITEM/WAARDE-rijen terug (secrets verborgen); $null als het geen ini-tabel is.
    param([string]$File)
    $dbf = Read-Dbf $File
    $names = $dbf.Fields | ForEach-Object { $_.Name.ToUpperInvariant() }
    if (-not ($names -contains 'SECTIE' -and $names -contains 'ITEM')) { return $null }
    foreach ($r in $dbf.Rows) {
        $s = "$($r.SECTIE)".Trim(); $it = "$($r.ITEM)".Trim(); $w = "$($r.WAARDE)".Trim()
        [pscustomobject]@{ SECTIE = $s; ITEM = $it; WAARDE = (Protect-Value $s $it $w) }
    }
}

function Find-IntroIn {
    param([string]$Dir, [int]$Depth = 1)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    Get-ChildItem -LiteralPath $Dir -Filter 'fs_intro*.dbf' -File -ErrorAction SilentlyContinue
    if ($Depth -gt 0) {
        Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Find-IntroIn $_.FullName ($Depth - 1) }
    }
}

function Search-Drives {
    $skip = @('Windows', '$Recycle.Bin', 'System Volume Information', 'WinSxS', 'node_modules', '.git', 'Recovery', 'Config.Msi')
    $drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
    foreach ($d in $drives) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($d.RootDirectory.FullName)
        $n = 0
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop(); $n++
            if ($n % 500 -eq 0) { Write-Progress -Activity "Schijf $($d.Name) doorzoeken" -Status $dir }
            try { foreach ($f in [IO.Directory]::GetFiles($dir, 'fs_intro*.dbf')) { Get-Item -LiteralPath $f } } catch { }
            try {
                foreach ($sub in (New-Object IO.DirectoryInfo($dir)).GetDirectories()) {
                    if ($skip -contains $sub.Name) { continue }
                    if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($sub.FullName)
                }
            } catch { }
        }
        Write-Progress -Activity "Schijf $($d.Name) doorzoeken" -Completed
    }
}

# ---------------------------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Out-Line "Florisoft Ini Finder  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  -  gebruiker $env:USERDOMAIN\$env:USERNAME" 'Cyan'
Out-Line ''

# 1. Kandidaat-mappen verzamelen -----------------------------------------------------------------
$candidates = New-Object 'System.Collections.Generic.List[string]'
function Add-Candidate([string]$d, [string]$why) {
    if (-not $d) { return }
    $d = $d.Trim('"').TrimEnd('\')
    if ($d -and -not ($candidates -contains $d) -and (Test-Path -LiteralPath $d -PathType Container)) {
        $candidates.Add($d)
        Out-Line ("  {0,-14} {1}" -f $why, $d) 'DarkGray'
    }
}

Out-Line '== Waar draait / staat Florisoft? ==' 'Yellow'
if ($Path) { Add-Candidate $Path '-Path' }
Add-Candidate (Get-Location).ProviderPath 'huidige map'

Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'flori' -or ($_.Path -and $_.Path -match 'florisoft') } | ForEach-Object {
    if ($_.Path) { Add-Candidate (Split-Path $_.Path -Parent) 'proces' }
}

try {
    $wsh = New-Object -ComObject WScript.Shell
    $lnkRoots = @("$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu", "$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'))
    $lnkRoots += Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'Desktop' }
    $lnkRoots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue
    } | ForEach-Object {
        try {
            $l = $wsh.CreateShortcut($_.FullName)
            if ($_.Name -match 'flori|fs.?2000' -or $l.TargetPath -match 'flori') {
                Out-Line ("  snelkoppeling  {0}  ->  {1}  (werkmap: {2})" -f $_.FullName, $l.TargetPath, $l.WorkingDirectory) 'DarkGray'
                Add-Candidate $l.WorkingDirectory 'werkmap lnk'
                if ($l.TargetPath) { Add-Candidate (Split-Path $l.TargetPath -Parent) 'doel lnk' }
            }
        } catch { }
    }
} catch { }

foreach ($drv in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
    Get-ChildItem -LiteralPath $drv.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'flori|^fs' } | ForEach-Object { Add-Candidate $_.FullName 'schijfroot' }
}
foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
    if ($pf -and (Test-Path -LiteralPath $pf)) {
        Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'flori' } | ForEach-Object { Add-Candidate $_.FullName 'Program Files' }
    }
}

# 2. FS_INTRO-bestanden zoeken -------------------------------------------------------------------
$intros = @($candidates | ForEach-Object { Find-IntroIn $_ 1 })
if ($Deep -or $intros.Count -eq 0) {
    if (-not $Deep) { Out-Line '  Niets gevonden op de bekende plekken; alle vaste schijven worden doorzocht (kan even duren)...' 'DarkYellow' }
    $intros += @(Search-Drives)
}
$intros = @($intros | Sort-Object FullName -Unique)

# Gekozen fs_intro uit user.config (Win_Choose2 bewaart de keuze per Windows-gebruiker)
$cfgRoots = @("$env:LOCALAPPDATA") + @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Local' })
$cfgRoots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'flori' } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'user.config' -ErrorAction SilentlyContinue }
} | ForEach-Object {
    $txt = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($txt -match '<setting name="fs_intro"[^>]*>\s*<value>([^<]*)</value>') {
        Out-Line ("  gekozen intro  '{0}'  (uit {1})" -f $Matches[1], $_.FullName) 'DarkGray'
    }
}

Out-Line ''
if ($intros.Count -eq 0) {
    Out-Line 'Geen FS_INTRO*.DBF gevonden. Geef de installatiemap mee met -Path, of draai met -Deep.' 'Red'
}

# 3. Per FS_INTRO: inhoud + datapad + Ini-mappen -------------------------------------------------
$outDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "Florisoft-Ini-$env:COMPUTERNAME-$stamp"
if (-not (Test-Path -LiteralPath (Split-Path $outDir -Parent))) { $outDir = Join-Path $env:TEMP "Florisoft-Ini-$env:COMPUTERNAME-$stamp" }
[void](New-Item -ItemType Directory -Path $outDir -Force)
$dataDirs = New-Object 'System.Collections.Generic.List[string]'

foreach ($intro in $intros) {
    Out-Line ("== {0} ==" -f $intro.FullName) 'Yellow'
    Out-Line ("   gewijzigd {0}, {1} bytes" -f $intro.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $intro.Length) 'DarkGray'
    try {
        $rows = @(Get-IniRows $intro.FullName)
    } catch {
        Out-Line "   Kan niet lezen: $($_.Exception.Message)" 'Red'; continue
    }
    foreach ($r in $rows) {
        Out-Line ("   {0,-28} {1}" -f "$($r.SECTIE)/$($r.ITEM)", $r.WAARDE) 'Gray' -ReportOnly:$Quiet
    }
    $safeName = ($intro.FullName -replace '[:\\/ ]+', '_')
    $rows | Export-Csv -LiteralPath (Join-Path $outDir "intro_$safeName.csv") -NoTypeInformation -Encoding UTF8 -Delimiter ';'

    $dd = ($rows | Where-Object { $_.SECTIE -eq 'DIRECTORIES' -and $_.ITEM -eq 'DATADIRECTORY' } | Select-Object -First 1).WAARDE
    if (-not $dd) { Out-Line '   Geen DIRECTORIES/DataDirectory in dit bestand.' 'DarkYellow'; Out-Line ''; continue }
    if (-not [IO.Path]::IsPathRooted($dd)) { $dd = Join-Path $intro.DirectoryName $dd }
    Out-Line ''
    Out-Line ("   DataDirectory = {0}" -f $dd) 'Green'
    if (-not ($dataDirs -contains $dd)) { $dataDirs.Add($dd) }
    Out-Line ''
}

foreach ($dd in $dataDirs) {
    Out-Line ("== Datapad {0} ==" -f $dd) 'Yellow'
    if (-not (Test-Path -LiteralPath $dd)) {
        Out-Line '   Niet bereikbaar vanaf deze machine/gebruiker (share niet gekoppeld of geen rechten?).' 'Red'; Out-Line ''; continue
    }
    $central = Join-Path $dd 'fsintro'
    if (Test-Path -LiteralPath $central) {
        Get-ChildItem -LiteralPath $central -Filter 'fs_intro*.dbf' -File -ErrorAction SilentlyContinue | ForEach-Object { Out-Line ("   centrale intro (CheckFSINTRO): {0}" -f $_.FullName) 'Gray' }
    }
    $iniRoot = Join-Path $dd 'Ini'
    if (-not (Test-Path -LiteralPath $iniRoot)) {
        Out-Line '   Geen Ini-map: waarschijnlijk een Postgres-installatie.' 'DarkYellow'
        Out-Line '   Gebruikersinstellingen staan dan in tabel ini.fsini (INIID, USERID, SECTIE, ITEM, WAARDE),' 'DarkYellow'
        Out-Line '   systeeminstellingen in FSSYSTEM.' 'DarkYellow'
        Out-Line ''; continue
    }
    $users = @(Get-ChildItem -LiteralPath $iniRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    Out-Line ("   Gebruikersinstellingen: {0}\<USERID>\FS_2000.DBF, FS_SETUP.DBF, ...  ({1} gebruikers)" -f $iniRoot, $users.Count) 'Green'
    foreach ($u in $users) {
        $files = @(Get-ChildItem -LiteralPath $u.FullName -Filter '*.dbf' -File -ErrorAction SilentlyContinue)
        $last = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $lastTxt = ''; if ($last) { $lastTxt = $last.LastWriteTime.ToString('yyyy-MM-dd') }
        Out-Line ("   {0,-14} {1,3} ini-bestanden, laatst gewijzigd {2}" -f $u.Name, $files.Count, $lastTxt) 'Gray'
    }
    $loose = @(Get-ChildItem -LiteralPath $iniRoot -Filter '*.dbf' -File -ErrorAction SilentlyContinue)
    if ($loose.Count) { Out-Line ("   + {0} bestanden direct in {1} (systeembrede ini's)" -f $loose.Count, $iniRoot) 'Gray' }

    if ($Export) {
        $targets = $users
        if ($User) { $targets = @($users | Where-Object { $_.Name -ieq $User.Trim() }) }
        if ($User -and $targets.Count -eq 0) { Out-Line "   Gebruiker '$User' niet gevonden in $iniRoot." 'Red' }
        $all = New-Object 'System.Collections.Generic.List[object]'
        $jobs = @($targets | ForEach-Object { $uu = $_; Get-ChildItem -LiteralPath $uu.FullName -Filter '*.dbf' -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ User = $uu.Name; File = $_ } } })
        if (-not $User) { $jobs += @($loose | ForEach-Object { [pscustomobject]@{ User = ''; File = $_ } }) }
        $k = 0
        foreach ($j in $jobs) {
            $k++; Write-Progress -Activity 'Ini-bestanden exporteren' -Status $j.File.FullName -PercentComplete (100 * $k / [Math]::Max(1, $jobs.Count))
            try {
                $iniId = ([IO.Path]::GetFileNameWithoutExtension($j.File.Name)).ToUpperInvariant()
                foreach ($r in @(Get-IniRows $j.File.FullName)) {
                    $all.Add([pscustomobject]@{ INIID = $iniId; USERID = $j.User; SECTIE = $r.SECTIE; ITEM = $r.ITEM; WAARDE = $r.WAARDE; BESTAND = $j.File.FullName })
                }
            } catch { Out-Line ("   Kan {0} niet lezen: {1}" -f $j.File.FullName, $_.Exception.Message) 'DarkYellow' }
        }
        Write-Progress -Activity 'Ini-bestanden exporteren' -Completed
        $csv = Join-Path $outDir ("fsini_{0}.csv" -f (($dd -replace '[:\\/ ]+', '_').Trim('_')))
        $all | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Out-Line ("   Export: {0} instellingen -> {1}" -f $all.Count, $csv) 'Green'
    }
    Out-Line ''
}

if (-not $Export -and $dataDirs.Count) {
    Out-Line 'Tip: draai met -Export (of -User <USERID>) om alle gebruikersinstellingen naar CSV te halen.' 'DarkGray'
}
if (-not $ShowSecrets) { Out-Line 'Wachtwoorden en sleutels zijn verborgen (gebruik -ShowSecrets om ze te tonen).' 'DarkGray' }

$report | Out-File -LiteralPath (Join-Path $outDir 'rapport.txt') -Encoding UTF8
$zip = "$outDir.zip"
try { Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -Force -ErrorAction Stop; $zipTxt = " en $zip" } catch { $zipTxt = '' }
Write-Host ''
Write-Host ("Rapport: {0}{1}" -f $outDir, $zipTxt) -ForegroundColor Cyan
