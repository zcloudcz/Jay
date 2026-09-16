# Inventura Azure bety (I01)

Read-only inventura provedená 2026-09-16 pomocí `az` CLI (verze 2.89.1, Bicep 0.46.1) proti
subscription `a8230148-f8c6-47f1-b27c-ad6c31c25dad` (potvrzeno `az account show`, tenant
`3443d5f9-684e-460e-99ae-c354c8265e9b`). Žádný `create`/`set`/`update`/`delete` nebyl proveden.

## Resource group `rg-calltype-beta`, West Europe

| Resource | Typ | Zjištěné vlastnosti |
| --- | --- | --- |
| `asp-calltype-beta` | Microsoft.Web/serverfarms | SKU `B1`/`Basic`, `kind: linux`, capacity `1`, žádný autoscale/maximumNumberOfWorkers |
| `calltype-beta-zahy` | Microsoft.Web/sites | `linuxFxVersion: DOTNETCORE|10.0`, `httpsOnly: true`, `minTlsVersion: 1.2`, `ftpsState: Disabled`, `alwaysOn: true`, `webSocketsEnabled: true`, `state: Running`, host `calltype-beta-zahy.azurewebsites.net` |
| `calltype-beta-web` | Microsoft.Web/staticSites | SKU `Free`, host `orange-bush-07e1b5803.6.azurestaticapps.net` |
| `calltypebetazahy` | Microsoft.Storage/storageAccounts | `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2`, SKU `Standard_LRS`, `kind: StorageV2` |

Vše sedí se záznamem v `docs/azure-beta-plan.md` z 2026-09-14; region, SKU a klíčové bezpečnostní
vlastnosti byly znovu ověřeny přímo z Azure, nejen převzaty z dokumentu.

## App settings (pouze názvy, žádné hodnoty)

`az webapp config appsettings list --name calltype-beta-zahy --resource-group rg-calltype-beta --query "[].name"`:

```
Jwt__Secret
Jwt__Issuer
Turn__TtlSeconds
Database__ApplyMigrationsOnStartup
ConnectionStrings__DefaultConnection
Turn__Provider
Turn__Cloudflare__KeyId
Turn__Cloudflare__ApiToken
ConnectionStrings__BlobStorage
Cors__AllowedOrigins__0
Cors__AllowedOrigins__1
ASPNETCORE_ENVIRONMENT
WEBSITE_HTTPLOGGING_RETENTION_DAYS
```

Odpovídá klíčům z K05 (`2026-09-16-beta-kontrakty.md`). `beta-appservice.bicep` tuto kolekci
nenastavuje a nesmí ji přepsat — viz `docs/ops/beta-infrastructure.md`.

## Outbound IP adresy (pro DB firewall)

`outboundIpAddresses`: `51.137.102.12, 51.137.99.214, 51.136.10.47, 51.137.55.160, 51.144.164.215`

`possibleOutboundIpAddresses` (širší množina, může se změnit při změně plánu/regionu):
`51.137.102.12, 51.137.99.214, 51.136.10.47, 51.137.55.160, 51.136.26.169, 51.136.54.230,
51.144.165.95, 20.82.60.92, 20.126.241.44, 20.126.241.113, 20.126.242.95, 20.126.243.41,
20.126.243.57, 20.23.189.1, 20.23.189.161, 20.23.190.163, 20.23.190.200, 20.23.191.204,
20.4.192.16, 51.144.164.215`

Aktuální `outboundIpAddresses` se shoduje s historickým seznamem v `docs/azure-beta-plan.md` až na
chybějící `20.50.2.95` — beze změny SKU/regionu nejde vyloučit budoucí posun. I02 nesmí tento
seznam brát jako trvalou garanci; DB firewall pravidla ověřit vůči aktuálnímu stavu před každou
změnou.

## Šablony, které se v tomto balíčku nenasazují

`infra/main.bicep` a `infra/beta-vm.bicep` popisují jinou/historickou topologii (spravovaná
PostgreSQL, případně VM). Nejsou cílem I01, nebyly čteny za účelem nasazení a `beta-appservice.bicep`
je nenahrazuje ani z nich nedědí.
