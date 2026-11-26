# Florisoft Ini Finder

Eén PowerShell-script dat op een Florisoft-machine uitzoekt waar de client-instellingen staan en ze uitleest. Het heeft geen Florisoft, ADS of admin-rechten nodig, maar als admin ziet het meer.

## Starten

In PowerShell op de Florisoft-machine, liefst vanuit de Florisoft-installatiemap:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://is.gd/florisoftini | iex
```

Volledige link (als is.gd geblokkeerd is): `https://raw.githubusercontent.com/bootfail/Florisoft-Ini-Finder/main/Find-FlorisoftIni.ps1`

Met opties:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm https://is.gd/florisoftini))) -Export
```

| Optie | Wat het doet |
|---|---|
| `-Path <map>` | extra map om te doorzoeken (installatiemap of share) |
| `-Deep` | alle vaste schijven volledig doorzoeken naar `fs_intro*.dbf` |
| `-Export` | alle gebruikers-ini's naar één CSV, plus een zip |
| `-User <USERID>` | alleen deze gebruiker exporteren (`-Export` gaat dan vanzelf aan) |
| `-ShowSecrets` | wachtwoorden en sleutels niet verbergen |
| `-Quiet` | de inhoud van FS_INTRO alleen in het rapport zetten, niet op het scherm |

Het rapport komt in `Bureaublad\Florisoft-Ini-<PC>-<tijd>` (plus `.zip`): `rapport.txt` en de CSV's.

## Wat het zoekt

1. **`FS-INTRO.INI`**: fysiek `FS_INTRO.DBF`, of `fs_intro - <host> - <map>.dbf`. Dit bestand staat in de werkmap van Florisoft.exe. Het script zoekt die map via de huidige map, draaiende processen, snelkoppelingen (doel en werkmap), Program Files en de mappen in de schijfroot. Vindt het daar niets, dan doorzoekt het alle schijven. Het bevat onder meer `DIRECTORIES/DataDirectory`.
2. **Gebruikersinstellingen**: `<DataDirectory>\Ini\<USERID>\FS_2000.DBF`, `FS_SETUP.DBF` enzovoort.
3. **Postgres-installaties** hebben geen `Ini`-map. Daar staat alles in de tabel `ini.fsini` (`INIID`, `USERID`, `SECTIE`, `ITEM`, `WAARDE`), en de systeeminstellingen in `FSSYSTEM`.

Een "ini" is in Florisoft een DBF-tabel met de kolommen `SECTIE`, `ITEM` en `WAARDE`. De naam `FS-xxx.INI` verwijst naar het bestand `FS_xxx.DBF`. Het script leest die DBF's zelf uit, inclusief `.FPT`-memo's, en dat lukt ook als Florisoft ze open heeft.

## KoWaDi-verzamelaar (`dist/Florisoft-KoWaDi-Verzamelaar.zip`)

Dit pakket verzamelt op een klantmachine alles wat nodig is om de KoWaDi-barcode op de pickorder-paklijst uit te zoeken met de Florisoft-MCP en de config-assistent. Je kunt het per WhatsApp of mail sturen. In de zip zitten `KoWaDi-Verzamelen.cmd` (zelfstandig, dubbelklikken) en `LEESMIJ.txt`.

Het pakket verzamelt:
- FS_INTRO en het datapad
- de Florisoft-versie
- `postgres.txt` (wachtwoorden verborgen)
- als `psql` aanwezig is: een export van `ini.fsini` (alle gebruikersinstellingen plus FSSYSTEM) en de KoWaDi-kolommen van `DEBITEUR`; anders `kowadi-export.sql` om op de databaseserver te draaien
- de relevante regels uit de oude Ini-DBF's
- de paklijstlayouts uit `<datapad>\Reports`, met een controle op `KowadiBarcode`

Het resultaat is een zip op het bureaublad, die de klant terugstuurt.

Bouwen: `powershell -File build.ps1`. Dat voegt de DBF-functies uit `Find-FlorisoftIni.ps1` in `src/KoWaDi-Verzamelen.ps1` in en schrijft `dist/`.

Direct downloaden: https://github.com/bootfail/Florisoft-Ini-Finder/raw/main/dist/Florisoft-KoWaDi-Verzamelaar.zip
