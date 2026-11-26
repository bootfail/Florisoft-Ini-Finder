<#
  Florisoft KoWaDi-verzamelaar
  Verzamelt op een Florisoft-machine alles wat nodig is om de KoWaDi-barcode op de pickorder-paklijst
  uit te zoeken met de Florisoft-MCP / config-assistent:
    - FS_INTRO en het datapad
    - Florisoft-versie
    - postgres.txt (wachtwoorden verborgen) en, als psql aanwezig is, een export van ini.fsini
      (alle gebruikersinstellingen + FSSYSTEM) en de KoWaDi-velden van DEBITEUR
    - relevante regels uit de oude Ini-DBF's
    - de paklijstlayouts (.FRPT) uit <datapad>\Reports, met controle op de variabele KowadiBarcode
  Resultaat: een zip op het bureaublad om terug te sturen.
#>
param([switch]$GeenDatabase)

$ErrorActionPreference = 'Continue'
$enc1252 = [Text.Encoding]::GetEncoding(1252)
$ShowSecrets = $false
$secretPattern = 'PASS|WACHTW|PWD|SECRET|TOKEN|APIKEY|API_KEY|CLIENTKEY|PRIVATE|CONNECTIONSTRING|CONNSTR|LICENTIE'
$relevantPattern = 'KASSABOXPAK/|PAKLIJST|KOWADI|PICKORDERPAKL|DOOSVUL|AUTOINPAK|PICKPAKL'

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

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { $desk = $env:TEMP }
$out = Join-Path $desk "Florisoft-KoWaDi-$env:COMPUTERNAME-$stamp"
[void](New-Item -ItemType Directory -Path $out -Force)
$log = New-Object 'System.Collections.Generic.List[string]'
function Say([string]$t = '', [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c; [void]$log.Add($t) }

Say "Florisoft KoWaDi-verzamelaar  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  -  $env:USERDOMAIN\$env:USERNAME" 'Cyan'
Say ''

# 1. FS_INTRO en datapad ----------------------------------------------------------------------------
Say '[1/6] Florisoft-installatie zoeken' 'Yellow'
$dirs = New-Object 'System.Collections.Generic.List[string]'
function Add-Dir([string]$d) {
    if (-not $d) { return }
    $d = $d.Trim('"').TrimEnd('\')
    if ($d -and -not $dirs.Contains($d) -and (Test-Path -LiteralPath $d -PathType Container)) { $dirs.Add($d) }
}
Add-Dir (Get-Location).ProviderPath
try {
    $wsh = New-Object -ComObject WScript.Shell
    $roots = @("$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu", "$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($lnk in @(Get-ChildItem -LiteralPath $roots -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        try {
            $l = $wsh.CreateShortcut($lnk.FullName)
            if ($lnk.Name -match 'flori|fs.?2000' -or $l.TargetPath -match 'flori') {
                Add-Dir $l.WorkingDirectory
                if ($l.WorkingDirectory) { Add-Dir (Split-Path $l.WorkingDirectory -Parent) }
                if ($l.TargetPath) { $p = Split-Path $l.TargetPath -Parent; Add-Dir $p; if ($p) { Add-Dir (Split-Path $p -Parent) } }
            }
        } catch { }
    }
} catch { }
foreach ($drv in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
    Get-ChildItem -LiteralPath $drv.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'flori|^fs' } | ForEach-Object { Add-Dir $_.FullName }
}
$intros = @($dirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'fs_intro*.dbf' -File -ErrorAction SilentlyContinue } |
    Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending)

$dataDirs = New-Object 'System.Collections.Generic.List[string]'
foreach ($i in $intros) {
    try {
        $rows = @(Get-IniRows $i.FullName)
        $rows | Export-Csv -LiteralPath (Join-Path $out ("intro_" + ($i.FullName -replace '[:\\/ ]+', '_') + ".csv")) -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        $dd = ($rows | Where-Object { $_.SECTIE -eq 'DIRECTORIES' -and $_.ITEM -eq 'DATADIRECTORY' } | Select-Object -First 1).WAARDE
        Say ("   {0}  (gewijzigd {1})  ->  datapad {2}" -f $i.FullName, $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $dd)
        if ($dd -and -not $dataDirs.Contains($dd)) { $dataDirs.Add($dd) }
    } catch { Say "   Kan $($i.FullName) niet lezen: $($_.Exception.Message)" 'Red' }
}
if ($dataDirs.Count -eq 0) {
    Say '   Geen FS_INTRO gevonden.' 'Red'
    $manual = Read-Host 'Geef het Florisoft-datapad (bijv. \\server\Florisoft\DataAdt), of Enter om te stoppen'
    if ($manual) { $dataDirs.Add($manual.Trim()) }
}
$dd = $null
if ($dataDirs.Count -gt 0) { $dd = $dataDirs[0].TrimEnd('\') }
if ($dataDirs.Count -gt 1) { Say ("   Meerdere datapaden; gebruikt wordt {0}" -f $dd) 'DarkYellow' }
if ($dd -and -not (Test-Path -LiteralPath $dd)) { Say "   Datapad $dd is niet bereikbaar vanaf deze machine/gebruiker." 'Red' }
Say ''

# 2. Versie ---------------------------------------------------------------------------------------------
Say '[2/6] Florisoft-versie' 'Yellow'
$verRows = foreach ($d in $dirs) {
    Get-ChildItem -Path $d -Recurse -Depth 3 -Include 'Florisoft*.exe', 'Florisoft.Application.dll', 'Florisoft.Base.dll' -File -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Bestand = $_.FullName; FileVersion = $_.VersionInfo.FileVersion; ProductVersion = $_.VersionInfo.ProductVersion; Gewijzigd = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } }
}
$verRows = @($verRows | Sort-Object Bestand -Unique)
$verRows | Export-Csv -LiteralPath (Join-Path $out 'versies.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
$verRows | Where-Object { $_.Bestand -match 'Florisoft\.Application\.dll$' } | ForEach-Object { Say ("   {0}  {1}" -f $_.FileVersion, $_.Bestand) 'Green' }
if (-not ($verRows | Where-Object { $_.Bestand -match 'Florisoft\.Application\.dll$' })) { $verRows | Select-Object -First 5 | ForEach-Object { Say ("   {0}  {1}" -f $_.FileVersion, $_.Bestand) } }
Say ''

# 3. Postgres? -------------------------------------------------------------------------------------------
Say '[3/6] Database' 'Yellow'
$isPg = $false; $server = ''; $port = 5432; $db = ''
if ($dd) {
    $pgTxt = Join-Path $dd 'postgres.txt'
    if (Test-Path -LiteralPath $pgTxt) {
        $isPg = $true
        $lines = @(Get-Content -LiteralPath $pgTxt -ErrorAction SilentlyContinue)
        $lines -replace '(?i)(password|pwd)\s*=\s*[^;]*', '$1=<verborgen>' | Out-File -LiteralPath (Join-Path $out 'postgres.txt') -Encoding UTF8
        foreach ($ln in $lines) {
            $kv = $ln.Split([char[]]'=', 2)
            if ($kv.Count -lt 2) { continue }
            switch ($kv[0].Trim().ToUpperInvariant()) {
                'SERVER' { $server = $kv[1].Trim() }
                'PORT' { [void][int]::TryParse($kv[1].Trim(), [ref]$port) }
                'DATABASE' { $db = $kv[1].Trim() }
                'CONNECTIONSTRING' {
                    foreach ($part in $kv[1].Split(';')) {
                        $p2 = $part.Split([char[]]'=', 2)
                        if ($p2.Count -lt 2) { continue }
                        switch -regex ($p2[0].Trim()) {
                            '^(?i)(host|server)$' { if (-not $server) { $server = $p2[1].Trim() } }
                            '^(?i)port$' { [void][int]::TryParse($p2[1].Trim(), [ref]$port) }
                            '^(?i)database$' { if (-not $db) { $db = $p2[1].Trim() } }
                        }
                    }
                }
            }
        }
        # Zelfde afleiding als Florisoft (DatabaseConnectionInfo): \\SERVER[:poort]\share\...\DATABASE\map
        if ($dd.StartsWith('\\')) {
            # Florisoft splitst het datapad met slash aan het eind: \\VSKO02\Florisoft\DataAdt\ -> DATAADT
            $parts = ($dd.TrimEnd('\') + '\').Split('\')
            $sp = $parts[2].Split(':')
            if (-not $server) { $server = $sp[0] }
            if ($sp.Count -gt 1) { [void][int]::TryParse($sp[1], [ref]$port) }
            if (-not $db) { if ($parts.Count -gt 4) { $db = $parts[$parts.Count - 2] } else { $db = $parts[$parts.Count - 1] -replace '(?i)\.add$', '' } }
        }
        $db = $db.ToUpperInvariant()
        Say ("   Postgres (postgres.txt aanwezig): server {0}, poort {1}, database {2}" -f $server, $port, $db) 'Green'
        Say '   De Ini-DBF-bestanden worden dan niet meer gebruikt; de instellingen staan in ini.fsini.' 'DarkGray'
    } else {
        Say '   Geen postgres.txt in het datapad: oude ADS-installatie, instellingen staan in de Ini-DBF-bestanden.' 'Green'
    }
}

$sqlFsini = "\copy (select iniid, userid, sectie, item, waarde from ini.fsini) to 'fsini.csv' csv header"
$sqlDeb = "\copy (select debnr, naam, podoosvul, pickkwdi, picklayout, picklay2, pickalways from debiteur) to 'debiteur_kowadi.csv' csv header"
$sqlCols = "\copy (select table_schema, table_name, column_name, data_type from information_schema.columns where lower(table_name) = 'debiteur' order by ordinal_position) to 'debiteur_kolommen.csv' csv header"
@(
    '-- Florisoft KoWaDi-export. Uitvoeren met psql op de database van Florisoft, bijvoorbeeld op de databaseserver:',
    "--   psql -h $server -p $port -U postgres -d $db -f kowadi-export.sql",
    '-- De CSV-bestanden komen in de huidige map. fsini.csv bevat alle gebruikersinstellingen en FSSYSTEM (iniid FSSYSTEM).',
    '-- Let op: fsini.csv kan wachtwoorden bevatten; de config-assistent verbergt die bij het uploaden.',
    $sqlFsini, $sqlDeb, $sqlCols
) | Out-File -LiteralPath (Join-Path $out 'kowadi-export.sql') -Encoding ASCII

$fsiniRows = @(); $debRows = @()
if ($isPg -and -not $GeenDatabase) {
    $psqlCands = @()
    $psqlCands += @(Get-Command psql.exe -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf -and (Test-Path -LiteralPath $pf)) {
            Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'postgres|pgadmin' } |
                ForEach-Object { $psqlCands += @(Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'psql.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        }
    }
    foreach ($d in $dirs) { $psqlCands += @(Get-ChildItem -Path $d -Recurse -Depth 4 -Filter 'psql.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    $psql = $psqlCands | Where-Object { $_ } | Select-Object -First 1
    if (-not $psql) {
        Say '   psql staat niet op deze machine. Draai kowadi-export.sql (zit in het pakket) met psql of pgAdmin op de databaseserver.' 'DarkYellow'
    } else {
        Say "   psql gevonden: $psql"
        $u = Read-Host "   Postgres-gebruiker voor $server/$db (Enter = postgres, 'skip' = overslaan)"
        if ($u -ne 'skip') {
            if (-not $u) { $u = 'postgres' }
            $sec = Read-Host "   Wachtwoord voor $u" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $env:PGCLIENTENCODING = 'UTF8'
            $outFwd = $out -replace '\\', '/'
            foreach ($q in @($sqlFsini, $sqlDeb, $sqlCols)) {
                $q2 = $q -replace "to '([^']+)'", "to '$outFwd/`$1'"
                $res = & $psql -h $server -p $port -U $u -d $db -w -c $q2 2>&1
                foreach ($r in @($res)) { Say ("   psql: {0}" -f $r) 'DarkGray' }
            }
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
            $fsiniCsv = Join-Path $out 'fsini.csv'
            if (Test-Path -LiteralPath $fsiniCsv) {
                # wachtwoorden e.d. verbergen voordat het bestand de deur uit gaat
                $fsiniRows = @(Import-Csv -LiteralPath $fsiniCsv -Encoding UTF8 | ForEach-Object {
                    $_.waarde = Protect-Value $_.sectie $_.item $_.waarde; $_ })
                $fsiniRows | Export-Csv -LiteralPath $fsiniCsv -NoTypeInformation -Encoding UTF8
                Say ("   fsini.csv: {0} instellingen (geheimen verborgen)" -f $fsiniRows.Count) 'Green'
                $fsiniRows | Where-Object { ("{0}/{1}" -f $_.sectie, $_.item).ToUpperInvariant() -match $relevantPattern -or ("{0}/{1}" -f $_.sectie, $_.item) -match '(?i)^SETUP/ViaKowadiNietPrinten$' } |
                    Export-Csv -LiteralPath (Join-Path $out 'fsini_kowadi_relevant.csv') -NoTypeInformation -Encoding UTF8
            }
            $debCsv = Join-Path $out 'debiteur_kowadi.csv'
            if (Test-Path -LiteralPath $debCsv) { $debRows = @(Import-Csv -LiteralPath $debCsv -Encoding UTF8); Say ("   debiteur_kowadi.csv: {0} debiteuren" -f $debRows.Count) 'Green' }
        }
    }
}
Say ''

# 4. Oude Ini-DBF's ----------------------------------------------------------------------------------------
Say '[4/6] Relevante regels uit de Ini-DBF-bestanden' 'Yellow'
$legacy = New-Object 'System.Collections.Generic.List[object]'
if ($dd -and (Test-Path -LiteralPath (Join-Path $dd 'Ini'))) {
    $iniRoot = Join-Path $dd 'Ini'
    $files = @(Get-ChildItem -LiteralPath $iniRoot -Filter '*.dbf' -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ U = ''; F = $_ } })
    $files += @(Get-ChildItem -LiteralPath $iniRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $uu = $_.Name; Get-ChildItem -LiteralPath $_.FullName -Filter '*.dbf' -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ U = $uu; F = $_ } } })
    foreach ($fsys in @('FSSYSTEM.DBF', 'fssystem.dbf')) { $p = Join-Path $dd $fsys; if (Test-Path -LiteralPath $p) { $files += [pscustomobject]@{ U = ''; F = (Get-Item -LiteralPath $p) }; break } }
    $k = 0
    foreach ($j in $files) {
        $k++; Write-Progress -Activity 'Ini-DBF-bestanden lezen' -Status $j.F.FullName -PercentComplete (100 * $k / [Math]::Max(1, $files.Count))
        try {
            $iniId = ([IO.Path]::GetFileNameWithoutExtension($j.F.Name)).ToUpperInvariant()
            foreach ($r in @(Get-IniRows $j.F.FullName)) {
                $key = ("{0}/{1}" -f $r.SECTIE, $r.ITEM).ToUpperInvariant()
                if ($key -match $relevantPattern -or $key -eq 'SETUP/VIAKOWADINIETPRINTEN') {
                    $legacy.Add([pscustomobject]@{ USERID = $j.U; INIID = $iniId; SECTIE = $r.SECTIE; ITEM = $r.ITEM; WAARDE = $r.WAARDE; BESTAND_GEWIJZIGD = $j.F.LastWriteTime.ToString('yyyy-MM-dd'); BESTAND = $j.F.FullName })
                }
            }
        } catch { }
    }
    Write-Progress -Activity 'Ini-DBF-bestanden lezen' -Completed
    $legacy | Export-Csv -LiteralPath (Join-Path $out 'ini_dbf_kowadi_relevant.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Say ("   {0} bestanden gelezen, {1} relevante regels" -f $files.Count, $legacy.Count)
    if ($isPg) { Say '   Let op: Postgres is actief, deze DBF-waarden zijn waarschijnlijk verouderd.' 'DarkYellow' }
} else { Say '   Geen Ini-map gevonden.' }
Say ''

# 5. Paklijstlayouts ---------------------------------------------------------------------------------------
Say '[5/6] Paklijstlayouts' 'Yellow'
$wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($r in @($fsiniRows)) { if ($r.sectie -match '^(?i)KassaBoxPak' -and $r.item -match '^(?i)Report' -and $r.waarde) { [void]$wanted.Add($r.waarde.Trim()) } }
foreach ($r in $legacy) { if ($r.SECTIE -match '^(?i)KassaBoxPak' -and $r.ITEM -match '^(?i)Report' -and $r.WAARDE) { [void]$wanted.Add($r.WAARDE.Trim()) } }
foreach ($r in @($debRows)) { foreach ($c in 'picklayout', 'picklay2') { $v = "$($r.$c)".Trim(); if ($v) { [void]$wanted.Add($v) } } }
$repDir = $null
if ($dd) { $repDir = Join-Path $dd 'Reports' }
if ($repDir -and (Test-Path -LiteralPath $repDir)) {
    $copyDir = Join-Path $out 'Reports'; [void](New-Item -ItemType Directory -Path $copyDir -Force)
    $reps = @(Get-ChildItem -LiteralPath $repDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(FRPT|RPT)$' })
    $list = New-Object 'System.Collections.Generic.List[object]'
    $copied = 0; $bytes = 0
    $k = 0
    foreach ($f in $reps) {
        $k++; Write-Progress -Activity 'Layouts controleren' -Status $f.Name -PercentComplete (100 * $k / [Math]::Max(1, $reps.Count))
        $hasKwd = $false
        if ($f.Length -lt 30MB) {
            try {
                $b = [IO.File]::ReadAllBytes($f.FullName)
                $hasKwd = ($enc1252.GetString($b) -match '(?i)kowadibarcode') -or ([Text.Encoding]::Unicode.GetString($b) -match '(?i)kowadibarcode')
            } catch { }
        }
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $isWanted = $wanted.Contains($base)
        $list.Add([pscustomobject]@{ Layout = $f.Name; Gewijzigd = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); Grootte = $f.Length; BevatKowadiBarcode = $hasKwd; InGebruikVolgensInstellingen = $isWanted })
        if (($hasKwd -or $isWanted -or $base -match '(?i)pak|kowadi|kwd') -and $copied -lt 80 -and $bytes -lt 150MB) {
            try { Copy-Item -LiteralPath $f.FullName -Destination $copyDir -ErrorAction Stop; $copied++; $bytes += $f.Length } catch { }
        }
    }
    Write-Progress -Activity 'Layouts controleren' -Completed
    $list | Sort-Object Layout | Export-Csv -LiteralPath (Join-Path $out 'layouts.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Say ("   {0} layouts in {1}; {2} gekopieerd" -f $reps.Count, $repDir, $copied)
    $list | Where-Object { $_.BevatKowadiBarcode } | ForEach-Object { Say ("   bevat KowadiBarcode: {0}" -f $_.Layout) 'Green' }
    if (-not ($list | Where-Object { $_.BevatKowadiBarcode })) { Say '   Geen layout gevonden waarin de tekst KowadiBarcode voorkomt.' 'DarkYellow' }
    foreach ($w in $wanted) { if (-not ($reps | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $w })) { Say ("   Layout uit instellingen niet gevonden in Reports: {0}" -f $w) 'DarkYellow' } }
} else { Say '   Reports-map niet gevonden of niet bereikbaar.' 'Red' }
Say ''

# 6. Inpakken ------------------------------------------------------------------------------------------------
Say '[6/6] Inpakken' 'Yellow'
$log | Out-File -LiteralPath (Join-Path $out 'rapport.txt') -Encoding UTF8
$zip = "$out.zip"
try {
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force -ErrorAction Stop
    Write-Host ''
    Write-Host "Klaar. Stuur dit bestand terug via WhatsApp:" -ForegroundColor Cyan
    Write-Host "   $zip" -ForegroundColor Cyan
    try { Start-Process explorer.exe -ArgumentList "/select,`"$zip`"" } catch { }
} catch {
    Write-Host "Zippen mislukt ($($_.Exception.Message)). Stuur de map terug: $out" -ForegroundColor Red
}
