# Bouwt dist\KoWaDi-Verzamelen.ps1, dist\KoWaDi-Verzamelen.cmd (zelfstandig) en dist\Florisoft-KoWaDi-Verzamelaar.zip
$root = $PSScriptRoot
$finder = [IO.File]::ReadAllText("$root\Find-FlorisoftIni.ps1")
$s = $finder.IndexOf('function Protect-Value'); $e = $finder.IndexOf('function Find-IntroIn')
if ($s -lt 0 -or $e -le $s) { throw 'Functies niet gevonden in Find-FlorisoftIni.ps1' }
$src = [IO.File]::ReadAllText("$root\src\KoWaDi-Verzamelen.ps1")
$full = $src.Replace('#INCLUDE-DBF', $finder.Substring($s, $e - $s).TrimEnd())
if ($full -match '[^\x00-\x7F]') { throw 'Niet-ASCII teken in het script; de .cmd leest als UTF-8 zonder BOM' }
$full = $full -replace "`r?`n", "`r`n"
$dist = "$root\dist"
[IO.File]::WriteAllText("$dist\KoWaDi-Verzamelen.ps1", $full, (New-Object Text.UTF8Encoding($false)))
$cmd = @(
  '@echo off',
  'title Florisoft KoWaDi-verzamelaar',
  'echo Florisoft KoWaDi-verzamelaar: gegevens verzamelen...',
  'powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=''%~f0''; $t=[IO.File]::ReadAllText($f); $m=''#''+''PSSTART''; iex $t.Substring($t.IndexOf($m))"',
  'echo.',
  'pause',
  'exit /b',
  '#PSSTART'
) -join "`r`n"
[IO.File]::WriteAllText("$dist\KoWaDi-Verzamelen.cmd", $cmd + "`r`n" + $full, (New-Object Text.UTF8Encoding($false)))
$leesmij = @(
  'Florisoft KoWaDi-verzamelaar',
  '',
  '1. Pak dit zip-bestand uit (of open het).',
  '2. Dubbelklik op KoWaDi-Verzamelen.cmd. Krijg je een blauwe Windows-waarschuwing: Meer informatie > Toch uitvoeren.',
  '3. Vraagt het script om een Postgres-gebruiker en wachtwoord en heb je die niet: typ skip.',
  '4. Aan het eind opent Verkenner met een zip op het bureaublad (Florisoft-KoWaDi-<pc>-<tijd>.zip).',
  '   Stuur die zip terug via WhatsApp.',
  '',
  'Het script verandert niets in Florisoft of de database; het leest alleen. Wachtwoorden worden verborgen.'
) -join "`r`n"
[IO.File]::WriteAllText("$dist\LEESMIJ.txt", $leesmij, (New-Object Text.UTF8Encoding($false)))
Remove-Item "$dist\Florisoft-KoWaDi-Verzamelaar.zip" -ErrorAction SilentlyContinue
Compress-Archive -Path "$dist\KoWaDi-Verzamelen.cmd", "$dist\LEESMIJ.txt" -DestinationPath "$dist\Florisoft-KoWaDi-Verzamelaar.zip"
Get-ChildItem $dist | Select-Object Name, Length
