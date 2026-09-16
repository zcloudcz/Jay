# Infrastruktura bety — provoz s `beta-appservice.bicep` (I01)

Šablona `infra/beta-appservice.bicep` popisuje schválenou topologii z
`docs/superpowers/plans/2026-09-16-beta-infrastruktura.md`: Linux App Service B1 (přesně 1 instance),
Static Web Apps Free, privátní Blob Storage. `infra/main.bicep` a `infra/beta-vm.bicep` jsou
historické a touto šablonou se nenasazují ani neupravují.

## App settings jsou mimo tuto šablonu

Azure `PUT` na kolekci app settings (`Microsoft.Web/sites/config/appsettings`) nahrazuje **celou**
kolekci. Kdyby `beta-appservice.bicep` obsahoval `siteConfig.appSettings` prázdný nebo neúplný,
nasazení by smazalo `Jwt__Secret`, `Turn__SharedSecret`, connection stringy i CORS origins uvedené v
`docs/ops/beta-inventory.md`. Proto šablona `appSettings` vůbec nenastavuje.

**Požadavek na R01:** deploy pipeline musí před zápisem app settings načíst existující kolekci
(`az webapp config appsettings list`), sloučit ji s novými/měněnými klíči a zapsat celek zpět
(read-merge-write), nikdy neposílat jen podmnožinu. Totéž platí pro `Cors__AllowedOrigins__N` a
`Turn__Urls__N` pole indexovaná číslem — chybějící index v novém zápisu pole zkrátí.

## Dvě cesty nasazení

### A) Převzetí existujícího prostředí (aktuální stav bety)

1. Ověřit shodu názvů/regionu s `docs/ops/beta-inventory.md`.
2. `az bicep build --file infra/beta-appservice.bicep --outfile <tmp>.json` → očekávat exit 0.
3. `az deployment group what-if --resource-group rg-calltype-beta --template-file infra/beta-appservice.bicep --parameters @infra/beta-appservice.parameters.example.json` a vysvětlit každý řádek diffu (viz `docs/ops/evidence/I01.md`).
4. Nejasný destruktivní diff (mazání DB/storage, druhá instance, změna hostingu, mazání app settings) = zastavit, neposílat `create`.
5. Skutečné `az deployment group create` provádí až určený operátor po schválení diffu z kroku 3, mimo rozsah tohoto balíčku (I01 dodává jen validaci, ne provedení).

### B) Instalace od nuly v novém, předem povoleném cíli

1. Zvolit novou resource group / názvy (musí být globálně unikátní pro web app, SWA a storage account).
2. Upravit `infra/beta-appservice.parameters.example.json` na nové názvy, region ponechat podle
   schváleného rozpočtu (West Europe má ověřenou cenu B1 v `docs/ops/beta-cost-model.md`).
3. `az bicep build` a `what-if` stejně jako výše — u nového cíle bude what-if ukazovat čisté `Create`.
4. Před prvním startem aplikace bezpečnou cestou (ne v repozitáři) doplnit `Jwt__Secret` (≥32 znaků,
   ne `REPLACE_ME_IN_PRODUCTION...` z `appsettings.json`), `Turn__SharedSecret`, connection stringy a
   CORS origin. Nikdy nenasazovat s výchozím vývojovým heslem/secretem.
5. Náklad nové placené instalace (druhý B1 plán, druhý storage account) vyžaduje samostatný souhlas s
   konkrétní částkou — tento balíček takový test sám neprovádí.

## Rozhraní pro R01

- Web app: `calltype-beta-zahy`, plán `asp-calltype-beta` (Linux B1, capacity 1), region West Europe.
- SWA: `calltype-beta-web`, SKU Free.
- Runtime: `.NET 10` (`linuxFxVersion: DOTNETCORE|10.0`), publikační příkaz zůstává existující
  `dotnet publish` workflow — nahradit nesoulad v `.github/workflows/deploy.yml` (staví do ACR/Container
  Apps) publikací do App Service; sám workflow needituje I01.
- Veřejné URL: `https://calltype-beta-zahy.azurewebsites.net`,
  `https://orange-bush-07e1b5803.6.azurestaticapps.net`.
- Pravidlo tajemství: nikdy nezapisovat hodnoty do Gitu/CI logů; jen názvy klíčů (viz
  `docs/ops/beta-inventory.md`).
- Jedna instance: `beta-appservice.bicep` fixuje `sku.capacity: 1` a nenabízí autoscale parametr;
  R01 nesmí capacity zvyšovat bez samostatného architektonického rozhodnutí (viz Global Constraints).
- `Proxy__KnownProxy`: neměnit bez ověření skutečného proxy řetězce s B00; tato šablona proxy
  nastavení vůbec neobsahuje (je součástí app settings, ne infra topologie).

## Rollback

Šablona mění pouze vlastnosti existujících prostředků (SKU, TLS, FTP, WebSockets, tagy) — nepoužívá
`complete` deployment mode ani mazání resource group. Návrat k předchozímu stavu:

1. Zaznamenat aktuální hodnoty vlastností před zásahem (tento dokument + `beta-inventory.md`).
2. Vrátit jednotlivou vlastnost (`az webapp config set ...`) nebo redeploy šablony s předchozími
   parametry — nikdy `az group delete` ani deployment mode `Complete`.
3. Aplikační artefakt (kód, ne infrastrukturu) vrací R01 samostatně.
4. Restart App Service přeruší aktivní hovory (jedna instance drží stav hovorů v paměti) — přiznat
   výpadek a po restartu ověřit, že klienti znovu navážou SignalR spojení a fronta zpráv se přehraje.
