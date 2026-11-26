@echo off
title Florisoft KoWaDi-Database
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; $t=[IO.File]::ReadAllText($f); $m='#'+'PSSTART'; iex $t.Substring($t.IndexOf($m))"
echo.
pause
exit /b
#PSSTART
<#
  Florisoft KoWaDi database-export
  Draaien op de databaseserver (of een pc met psql). Exporteert uit de Florisoft-Postgres-database:
    - ini.fsini  (alle gebruikersinstellingen + FSSYSTEM), wachtwoorden verborgen
    - de KoWaDi-kolommen van DEBITEUR
  en zet een samenvatting van de KoWaDi-instellingen in rapport.txt. Resultaat: zip op het bureaublad.
  Het script leest alleen; het wijzigt niets in de database.

  Opties: -Server <naam> -Port <nr> -Database <naam> -User <gebruiker> -Psql <pad naar psql.exe>
#>
param(
    [string]$Server,
    [int]$Port = 0,
    [string]$Database,
    [string]$User = 'postgres',
    [string]$Psql
)

$ErrorActionPreference = 'Continue'
$enc1252 = [Text.Encoding]::GetEncoding(1252)
$ShowSecrets = $false
$secretPattern = 'PASS|WACHTW|PWD|SECRET|TOKEN|APIKEY|API_KEY|CLIENTKEY|PRIVATE|CONNECTIONSTRING|CONNSTR|LICENTIE'

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
$out = Join-Path $desk "Florisoft-KoWaDi-DB-$env:COMPUTERNAME-$stamp"
$raw = Join-Path $env:TEMP "fs-kowadi-raw-$stamp"
[void](New-Item -ItemType Directory -Path $out -Force)
[void](New-Item -ItemType Directory -Path $raw -Force)
$log = New-Object 'System.Collections.Generic.List[string]'
function Say([string]$t = '', [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c; [void]$log.Add($t) }
function Q-Ident([string]$n) { '"' + $n.Replace('"', '""') + '"' }
function Q-Lit([string]$s) { "'" + $s.Replace("'", "''") + "'" }
function Test-True([string]$v) { return ("$v".Trim() -match '^(?i)(t|true|1|y|yes|j|ja|on)$') }

function Finish([string]$msg, [string]$color = 'Cyan') {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $raw -Recurse -Force -ErrorAction SilentlyContinue
    $log | Out-File -LiteralPath (Join-Path $out 'rapport.txt') -Encoding UTF8
    $zip = "$out.zip"
    try {
        Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force -ErrorAction Stop
        Write-Host ''
        Write-Host $msg -ForegroundColor $color
        Write-Host "Stuur dit bestand terug: $zip" -ForegroundColor Cyan
        try { Start-Process explorer.exe -ArgumentList "/select,`"$zip`"" } catch { }
    } catch { Write-Host "Zippen mislukt; stuur de map terug: $out" -ForegroundColor Red }
}

Say "Florisoft KoWaDi database-export  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  -  $env:USERDOMAIN\$env:USERNAME" 'Cyan'
Say ''

# 1. psql zoeken ---------------------------------------------------------------------------------------------
Say '[1/5] psql zoeken' 'Yellow'
$found = New-Object 'System.Collections.Generic.List[string]'
$dataDirs = New-Object 'System.Collections.Generic.List[string]'
function Add-Psql([string]$p) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and -not $found.Contains($p)) { $found.Add($p) } }
if ($Psql) { Add-Psql $Psql }
Get-Command psql.exe -ErrorAction SilentlyContinue | ForEach-Object { Add-Psql $_.Source }
# Postgres-service: het pad naar pg_ctl.exe/postgres.exe wijst naar de bin-map; -D geeft de datamap (voor de poort)
$pgServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match '(?i)pg_ctl\.exe|postgres\.exe' })
foreach ($svc in $pgServices) {
    Say ("   service: {0} ({1})" -f $svc.Name, $svc.State) 'DarkGray'
    if ($svc.PathName -match '^\s*"?([^"]+?\.exe)') { Add-Psql (Join-Path (Split-Path $Matches[1] -Parent) 'psql.exe') }
    if ($svc.PathName -match '-D\s+"([^"]+)"' -or $svc.PathName -match '-D\s+(\S+)') { $dataDirs.Add($Matches[1].Trim('"')) }
}
foreach ($rk in @('HKLM:\SOFTWARE\PostgreSQL\Installations', 'HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Installations')) {
    Get-ChildItem -Path $rk -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($p.'Base Directory') { Add-Psql (Join-Path $p.'Base Directory' 'bin\psql.exe') }
        if ($p.'Data Directory') { $dataDirs.Add($p.'Data Directory') }
    }
}
if ($found.Count -eq 0) {
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($pf -and (Test-Path -LiteralPath $pf)) {
            Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)postgres|pgadmin|edb|pgsql' } |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'psql.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { Add-Psql $_.FullName } }
        }
    }
}
$drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
if ($found.Count -eq 0) {
    foreach ($d in $drives) {
        Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)postgres|pgsql|^pg|edb|florisoft' } |
            ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -Depth 4 -Filter 'psql.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { Add-Psql $_.FullName } }
    }
}
if ($found.Count -eq 0) {
    Say '   Niet op de bekende plekken; alle schijven worden doorzocht (kan even duren)...' 'DarkYellow'
    $skip = @('Windows', '$Recycle.Bin', 'System Volume Information', 'WinSxS', 'node_modules', '.git')
    foreach ($d in $drives) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($d.RootDirectory.FullName); $n = 0
        while ($stack.Count -gt 0 -and $found.Count -eq 0) {
            $dir = $stack.Pop(); $n++
            if ($n % 500 -eq 0) { Write-Progress -Activity "psql zoeken op $($d.Name)" -Status $dir }
            try { foreach ($f in [IO.Directory]::GetFiles($dir, 'psql.exe')) { Add-Psql $f } } catch { }
            try { foreach ($sub in (New-Object IO.DirectoryInfo($dir)).GetDirectories()) { if ($skip -notcontains $sub.Name -and -not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub.FullName) } } } catch { }
        }
        Write-Progress -Activity "psql zoeken op $($d.Name)" -Completed
    }
}
if ($found.Count -eq 0) {
    Say '   psql.exe niet gevonden op deze machine.' 'Red'
    $manual = Read-Host '   Geef het volledige pad naar psql.exe (Enter = stoppen)'
    if ($manual) { Add-Psql $manual.Trim('"') }
}
if ($found.Count -eq 0) { Finish 'Gestopt: geen psql.exe. Draai dit script op de databaseserver, of installeer de PostgreSQL command line tools.' 'Red'; return }
$psqlExe = ($found | Sort-Object { try { [version]((Get-Item -LiteralPath $_).VersionInfo.ProductVersion -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } -Descending | Select-Object -First 1)
$found | ForEach-Object { Say "   gevonden: $_" 'DarkGray' }
Say ("   gebruikt: {0}  ({1})" -f $psqlExe, ((& $psqlExe --version 2>&1) -join ' ')) 'Green'
Say ''

# 2. Server, poort, aanmelden ----------------------------------------------------------------------------------
Say '[2/5] Verbinden' 'Yellow'
if (-not $Server) {
    if ($pgServices.Count -gt 0) { $Server = 'localhost' }
    else { $Server = Read-Host '   Geen Postgres-service op deze machine. Naam of IP van de databaseserver' }
}
if ($Port -le 0) {
    foreach ($dd in $dataDirs) {
        foreach ($conf in @('postgresql.auto.conf', 'postgresql.conf')) {
            $cf = Join-Path $dd $conf
            if ($Port -le 0 -and (Test-Path -LiteralPath $cf)) {
                $m = Select-String -LiteralPath $cf -Pattern '^\s*port\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
                if ($m) { $Port = [int]$m.Matches[0].Groups[1].Value }
            }
        }
    }
    if ($Port -le 0) { $Port = 5432 }
}
$env:PGCLIENTENCODING = 'UTF8'
$sqlFile = Join-Path $raw 'q.sql'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Invoke-Psql([string]$db, [string]$sql, [switch]$Rows) {
    [IO.File]::WriteAllText($sqlFile, $sql + "`n", $utf8NoBom)
    $a = @('-X', '-w', '-v', 'ON_ERROR_STOP=1', '-h', $Server, '-p', "$Port", '-U', $User, '-d', $db)
    if ($Rows) { $a += @('-A', '-t', '-F', '|') }
    $a += @('-f', $sqlFile)
    $o = @(& $psqlExe @a 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $o; Text = ($o -join "`n") }
}

$adminDb = 'postgres'
$connected = $false
for ($try = 1; $try -le 4 -and -not $connected; $try++) {
    Say ("   poging {0}: {1}@{2}:{3}" -f $try, $User, $Server, $Port) 'DarkGray'
    $r = Invoke-Psql $adminDb 'select 1;' -Rows
    if ($r.Ok) { $connected = $true; break }
    if ($r.Text -match '(?i)database "postgres" does not exist') { $adminDb = 'template1'; $try--; continue }
    Say ("   {0}" -f (($r.Out | Where-Object { $_ -match '\S' } | Select-Object -First 2) -join ' / ')) 'DarkYellow'
    if ($try -ge 4) { break }
    if ($r.Text -match '(?i)password|authenticat|wachtwoord|fe_sendauth|role .* does not exist') {
        $u = Read-Host "   Postgres-gebruiker (Enter = $User)"
        if ($u) { $User = $u }
        $sec = Read-Host "   Wachtwoord voor $User" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        $s = Read-Host "   Kan niet verbinden. Server (Enter = $Server)"
        if ($s) { $Server = $s }
        $p = Read-Host "   Poort (Enter = $Port)"
        if ($p -match '^\d+$') { $Port = [int]$p }
    }
}
if (-not $connected) { Finish 'Gestopt: geen verbinding met de database (zie rapport.txt).' 'Red'; return }
Say ("   verbonden als {0} met {1}:{2}" -f $User, $Server, $Port) 'Green'

# Database kiezen
$dbs = @((Invoke-Psql $adminDb 'select datname from pg_database where not datistemplate order by datname;' -Rows).Out | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
Say ("   databases: {0}" -f ($dbs -join ', ')) 'DarkGray'
if ($Database -and -not ($dbs | Where-Object { $_ -ieq $Database })) {
    Say ("   database {0} bestaat niet op deze server; automatisch kiezen" -f $Database) 'DarkYellow'
    $Database = $null
}
if ($Database) { $Database = ($dbs | Where-Object { $_ -ieq $Database } | Select-Object -First 1) }
if (-not $Database) {
    # Florisoft noemt de database naar de laatste map van het datapad (bijv. ...\DataAdt -> DATAADT)
    $hits = @($dbs | Where-Object { $_ -ieq 'FLORISOFT' -or $_ -ieq 'DATAADT' })
    if ($hits.Count -eq 0) { $hits = @($dbs | Where-Object { $_ -match '(?i)flori|data' }) }
    if ($hits.Count -eq 0) { $hits = @($dbs | Where-Object { $_ -notmatch '^(?i)postgres$' }) }
    if ($hits.Count -eq 1) { $Database = $hits[0] }
    else {
        for ($i = 0; $i -lt $dbs.Count; $i++) { Write-Host ("     {0}. {1}" -f ($i + 1), $dbs[$i]) }
        $keuze = Read-Host '   Welke database is Florisoft? (nummer)'
        if ($keuze -match '^\d+$' -and [int]$keuze -ge 1 -and [int]$keuze -le $dbs.Count) { $Database = $dbs[[int]$keuze - 1] }
    }
}
if (-not $Database) { Finish 'Gestopt: geen database gekozen.' 'Red'; return }
Say ("   database: {0}" -f $Database) 'Green'
Say ''

# 3. Tabellen en kolommen ----------------------------------------------------------------------------------------
Say '[3/5] Tabellen controleren' 'Yellow'
function Find-Table([string]$name, [string]$preferSchema) {
    $q = "select table_schema, table_name from information_schema.tables where lower(table_name) = $(Q-Lit $name.ToLowerInvariant()) order by (lower(table_schema) = $(Q-Lit $preferSchema)) desc, table_schema;"
    $res = Invoke-Psql $Database $q -Rows
    $tabs = @($res.Out | Where-Object { $_ -match '\|' } | ForEach-Object { $x = $_.Split('|'); [pscustomobject]@{ Schema = $x[0].Trim(); Name = $x[1].Trim() } })
    if (-not $res.Ok) { Say ("   fout bij zoeken naar {0}: {1}" -f $name, $res.Text) 'Red' }
    return $tabs
}
function Get-Columns($t) {
    $q = "select column_name from information_schema.columns where table_schema = $(Q-Lit $t.Schema) and table_name = $(Q-Lit $t.Name) order by ordinal_position;"
    return @((Invoke-Psql $Database $q -Rows).Out | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
}
$fsiniT = @(Find-Table 'fsini' 'ini')
$debT = @(Find-Table 'debiteur' 'public')
Say ("   fsini:    {0}" -f (($fsiniT | ForEach-Object { "$($_.Schema).$($_.Name)" }) -join ', ')) 'DarkGray'
Say ("   debiteur: {0}" -f (($debT | ForEach-Object { "$($_.Schema).$($_.Name)" }) -join ', ')) 'DarkGray'
Say ''

# 4. Exporteren -----------------------------------------------------------------------------------------------------
Say '[4/5] Exporteren' 'Yellow'
$rawFwd = $raw -replace '\\', '/'
$fsiniRows = @(); $debRows = @()
if ($fsiniT.Count -gt 0) {
    $t = $fsiniT[0]
    $cols = Get-Columns $t
    $want = @('iniid', 'userid', 'sectie', 'item', 'waarde')
    $sel = @($want | ForEach-Object { $w = $_; $cols | Where-Object { $_ -ieq $w } | Select-Object -First 1 })
    $selSql = '*'; if ($sel.Count -eq $want.Count) { $selSql = (($sel | ForEach-Object { Q-Ident $_ }) -join ', ') }
    $r = Invoke-Psql $Database ("\copy (select $selSql from $(Q-Ident $t.Schema).$(Q-Ident $t.Name)) to $(Q-Lit "$rawFwd/fsini.csv") csv header")
    if ($r.Ok -and (Test-Path -LiteralPath "$raw\fsini.csv")) {
        $fsiniRows = @(Import-Csv -LiteralPath "$raw\fsini.csv" -Encoding UTF8)
        $red = 0
        foreach ($row in $fsiniRows) {
            $nw = Protect-Value $row.sectie $row.item $row.waarde
            if ($nw -ne $row.waarde) { $red++; $row.waarde = $nw }
        }
        $fsiniRows | Export-Csv -LiteralPath (Join-Path $out 'fsini.csv') -NoTypeInformation -Encoding UTF8
        Say ("   fsini.csv: {0} instellingen, {1} geheimen verborgen" -f $fsiniRows.Count, $red) 'Green'
    } else { Say ("   fsini export mislukt: {0}" -f $r.Text) 'Red' }
} else { Say '   Tabel fsini niet gevonden.' 'Red' }

if ($debT.Count -gt 0) {
    $t = $debT[0]
    $cols = Get-Columns $t
    $cols | ForEach-Object { [pscustomobject]@{ kolom = $_ } } | Export-Csv -LiteralPath (Join-Path $out 'debiteur_kolommen.csv') -NoTypeInformation -Encoding UTF8
    # vlbarc = ExternVoorloopKowadi: zonder deze voorloop maakt Florisoft geen KoWaDi-barcode (DoosVullenViaFactuur.GetKowadiBarcode)
    $want = @('debnr', 'naam', 'podoosvul', 'pickkwdi', 'vlbarc', 'picklayout', 'picklay2', 'pickalways')
    $sel = New-Object 'System.Collections.Generic.List[string]'
    foreach ($w in $want) { $c = $cols | Where-Object { $_ -ieq $w } | Select-Object -First 1; if ($c) { $sel.Add($c) } }
    if (-not ($sel | Where-Object { $_ -ieq 'naam' })) { $c = $cols | Where-Object { $_ -ieq 'debnaam' } | Select-Object -First 1; if ($c) { $sel.Insert([Math]::Min(1, $sel.Count), $c) } }
    foreach ($c in $cols) { if ($c -match '(?i)kowadi|kwdi|kwd' -and $c -notmatch '(?i)pass|pwd|wachtw' -and -not $sel.Contains($c)) { $sel.Add($c) } }
    $missing = @($want | Where-Object { $w = $_; -not ($cols | Where-Object { $_ -ieq $w }) } | Where-Object { $_ -ne 'naam' -or -not ($cols -contains 'debnaam') })
    if ($missing.Count) { Say ("   kolommen niet gevonden in debiteur: {0}" -f ($missing -join ', ')) 'DarkYellow' }
    if ($sel.Count -gt 0) {
        $r = Invoke-Psql $Database ("\copy (select $((($sel | ForEach-Object { Q-Ident $_ }) -join ', ')) from $(Q-Ident $t.Schema).$(Q-Ident $t.Name)) to $(Q-Lit "$rawFwd/debiteur.csv") csv header")
        if ($r.Ok -and (Test-Path -LiteralPath "$raw\debiteur.csv")) {
            $debRows = @(Import-Csv -LiteralPath "$raw\debiteur.csv" -Encoding UTF8)
            $debRows | Export-Csv -LiteralPath (Join-Path $out 'debiteur_kowadi.csv') -NoTypeInformation -Encoding UTF8
            Say ("   debiteur_kowadi.csv: {0} debiteuren, kolommen {1}" -f $debRows.Count, ($sel -join ', ')) 'Green'
        } else { Say ("   debiteur export mislukt: {0}" -f $r.Text) 'Red' }
    }
} else { Say '   Tabel debiteur niet gevonden.' 'Red' }
Say ''

# 5. Samenvatting KoWaDi -------------------------------------------------------------------------------------------
Say '[5/5] KoWaDi-instellingen' 'Yellow'
function Get-Ini([string]$iniid, [string]$sectie, [string]$item) {
    @($fsiniRows | Where-Object { $_.iniid -ieq $iniid -and $_.sectie -ieq $sectie -and $_.item -ieq $item })
}
if ($fsiniRows.Count -gt 0) {
    foreach ($k in @(@('SETUP', 'PickorderPaklstDoosVullenFust', 'fustcode voor inpakken; leeg = nooit een KoWaDi-barcode op de paklijst'),
                     @('SETUP', 'PickorderPaklijstAutoInpakken', 'factuurregels automatisch inpakken (andere functie)'),
                     @('SETUP', 'PickPaklsVolumeDragerFactuur', 'volumedrager van de factuur als fustcode'))) {
        $v = @(Get-Ini 'FSSYSTEM' $k[0] $k[1])
        $txt = 'niet ingesteld'; if ($v.Count) { $txt = "'" + $v[0].waarde + "'" }
        Say ("   FSSYSTEM  {0}/{1} = {2}   ({3})" -f $k[0], $k[1], $txt, $k[2])
    }
    Say '   Paklijstlayout per gebruiker (FS_TELEVERKOOP KassaBoxPak/Report):'
    $fsiniRows | Where-Object { $_.iniid -ieq 'FS_TELEVERKOOP' -and $_.sectie -ieq 'KassaBoxPak' -and $_.item -ieq 'Report' } |
        Group-Object waarde | ForEach-Object { Say ("      {0,-22} {1}" -f $_.Name, (($_.Group | ForEach-Object { $_.userid } | Sort-Object) -join ', ')) }
    Say '   Box: Kowadi-scan alleen binnenmelden (FS_BOX SETUP/ViaKowadiNietPrinten):'
    $vk = @($fsiniRows | Where-Object { $_.iniid -ieq 'FS_BOX' -and $_.sectie -ieq 'SETUP' -and $_.item -ieq 'ViaKowadiNietPrinten' })
    if ($vk.Count) { $vk | Group-Object waarde | ForEach-Object { Say ("      {0,-22} {1}" -f $_.Name, (($_.Group | ForEach-Object { $_.userid } | Sort-Object) -join ', ')) } } else { Say '      bij niemand ingesteld' }
    $rel = @($fsiniRows | Where-Object { ("{0}/{1}" -f $_.sectie, $_.item) -match '(?i)kowadi|paklijst|pakl|doosvul|kassaboxpak' })
    $rel | Export-Csv -LiteralPath (Join-Path $out 'fsini_kowadi_relevant.csv') -NoTypeInformation -Encoding UTF8
    Say ("   {0} KoWaDi/paklijst-gerelateerde regels in fsini_kowadi_relevant.csv" -f $rel.Count)
}
if ($debRows.Count -gt 0) {
    $hasPo = $debRows[0].PSObject.Properties.Name -contains 'podoosvul'
    $hasKw = $debRows[0].PSObject.Properties.Name -contains 'pickkwdi'
    $sel = @($debRows | Where-Object { ($hasPo -and (Test-True $_.podoosvul)) -or ($hasKw -and (Test-True $_.pickkwdi)) -or ("$($_.picklayout)".Trim()) -or ("$($_.picklay2)".Trim()) })
    $nPo = 0; $nKw = 0
    if ($hasPo) { $nPo = @($debRows | Where-Object { Test-True $_.podoosvul }).Count }
    if ($hasKw) { $nKw = @($debRows | Where-Object { Test-True $_.pickkwdi }).Count }
    $nVl = @($debRows | Where-Object { "$($_.vlbarc)".Trim() }).Count
    Say ("   Debiteuren: {0} met 'factuurregels inpakken' (PODOOSVUL), {1} met 'Kowadi versturen' (PICKKWDI), {2} met KoWaDi-voorloop (VLBARC), {3} met een afwijkende paklijstlayout of een van beide" -f $nPo, $nKw, $nVl, $sel.Count)
    $debRows | Where-Object { "$($_.vlbarc)".Trim() } | Select-Object -First 40 | ForEach-Object { Say ("      VLBARC {0,-10} {1,-30} voorloop={2} doosvul={3} kwdi={4} layout={5}" -f "$($_.debnr)".Trim(), "$($_.naam)$($_.debnaam)".Trim(), "$($_.vlbarc)".Trim(), "$($_.podoosvul)", "$($_.pickkwdi)", "$($_.picklayout)".Trim()) }
    $debRows | Group-Object { "$($_.picklayout)".Trim() } | Sort-Object Count -Descending | ForEach-Object { Say ("      afwijkende paklijstlayout {0,-14} bij {1} debiteuren" -f $(if ($_.Name) { $_.Name } else { '(geen)' }), $_.Count) }
    $sel | Select-Object -First 15 | ForEach-Object { Say ("      {0,-10} {1,-30} doosvul={2} kwdi={3} layout={4} layout2={5}" -f "$($_.debnr)".Trim(), "$($_.naam)$($_.debnaam)".Trim(), "$($_.podoosvul)", "$($_.pickkwdi)", "$($_.picklayout)".Trim(), "$($_.picklay2)".Trim()) }
    if ($sel.Count -gt 15) { Say ("      ... en nog {0} (zie debiteur_kowadi.csv)" -f ($sel.Count - 15)) }
}
Finish 'Klaar.'
