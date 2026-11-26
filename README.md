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
