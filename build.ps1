# Bouwt per script in src\ een volledige .ps1 en een zelfstandige .cmd in dist\, plus dist\Florisoft-KoWaDi-Verzamelaar.zip.
# De DBF-/redactiefuncties komen uit Find-FlorisoftIni.ps1 (placeholder #INCLUDE-DBF).
$root = $PSScriptRoot
$dist = "$root\dist"
$finder = [IO.File]::ReadAllText("$root\Find-FlorisoftIni.ps1")
$s = $finder.IndexOf('function Protect-Value'); $e = $finder.IndexOf('function Find-IntroIn')
if ($s -lt 0 -or $e -le $s) { throw 'Functies niet gevonden in Find-FlorisoftIni.ps1' }
$funcs = $finder.Substring($s, $e - $s).TrimEnd()
$utf8 = New-Object Text.UTF8Encoding($false)
$built = @()
foreach ($name in 'KoWaDi-Verzamelen', 'KoWaDi-Database') {
    $full = [IO.File]::ReadAllText("$root\src\$name.ps1").Replace('#INCLUDE-DBF', $funcs)
    if ($full -match '[^\x00-\x7F]') { throw "Niet-ASCII teken in $name; de .cmd leest als UTF-8 zonder BOM" }
    $full = $full -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText("$dist\$name.ps1", $full, $utf8)
    $cmd = @(
        '@echo off',
        "title Florisoft $name",
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=''%~f0''; $t=[IO.File]::ReadAllText($f); $m=''#''+''PSSTART''; iex $t.Substring($t.IndexOf($m))"',
        'echo.',
        'pause',
        'exit /b',
        '#PSSTART'
    ) -join "`r`n"
    [IO.File]::WriteAllText("$dist\$name.cmd", $cmd + "`r`n" + $full, $utf8)
    $built += "$dist\$name.cmd"
}
$leesmij = @(
    'Florisoft KoWaDi-pakket',
    '',
    'KoWaDi-Verzamelen.cmd  -> op een Florisoft-werkplek. Zoekt de installatie, layouts en instellingen.',
    'KoWaDi-Database.cmd    -> op de databaseserver (waar PostgreSQL draait). Exporteert de instellingen',
    '                          (ini.fsini) en de KoWaDi-velden van de debiteuren. Zoekt psql zelf op.',
    '',
    'Dubbelklik op het juiste bestand. Blauwe Windows-waarschuwing: Meer informatie > Toch uitvoeren.',
    'Vraagt het database-script om een gebruiker/wachtwoord: gebruik de postgres-beheerder.',
    'Aan het eind opent Verkenner met een zip op het bureaublad. Stuur die zip terug.',
    '',
    'De scripts lezen alleen; ze wijzigen niets in Florisoft of de database. Wachtwoorden worden verborgen.'
) -join "`r`n"
[IO.File]::WriteAllText("$dist\LEESMIJ.txt", $leesmij, $utf8)
Remove-Item "$dist\Florisoft-KoWaDi-Verzamelaar.zip" -ErrorAction SilentlyContinue
Compress-Archive -Path ($built + "$dist\LEESMIJ.txt") -DestinationPath "$dist\Florisoft-KoWaDi-Verzamelaar.zip"
Get-ChildItem $dist | Select-Object Name, Length
