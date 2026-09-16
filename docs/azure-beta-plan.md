# Azure beta deployment

Updated 14 September 2026. The approved beta uses **Linux App Service B1, PostgreSQL and coturn on the existing server, and a maximum USD 20/month budget**. The API and web client are deployed. Hosted API and TURN relay checks passed; real audio/video calls across separate networks and native-device acceptance remain pending.

The earlier `infra/beta-vm.bicep` and `infra/beta-compose.yml` are **superseded and not to be deployed**. Existing managed-services `infra/main.bicep` is also not the implementation of this revision.

## Created infrastructure

- Resource group: `rg-calltype-beta`, West Europe.
- App Service plan: `asp-calltype-beta`, Linux B1, one worker; retail estimate USD 13.14 per 730 hours.
- Web app: `calltype-beta-zahy`, .NET 10, [API health endpoint](https://calltype-beta-zahy.azurewebsites.net/health), verified healthy.
- Web client: `calltype-beta-web`, Static Web Apps Free, [CallType beta](https://orange-bush-07e1b5803.6.azurestaticapps.net), compiled with the Azure API URL.
- Private backup storage: `calltypebetazahy`, Standard_LRS, configured in the API.
- Always On and WebSockets enabled; HTTPS only, minimum TLS 1.2, FTP disabled.

PostgreSQL runs outside Azure at `187.127.83.154:5544`, database and dedicated user `calltype_prod`. Authentication from Azure succeeded over TLS 1.3, and three migrations were applied. The current connection uses `SSL Mode=Require`, which encrypts traffic but does not verify the server certificate. Certificate verification remains a hardening task. Database, JWT, Blob and TURN secrets are configured in Azure and must stay out of documentation. TURN credential TTL is 3600 seconds.

Public API checks passed for HTTP and SignalR direct/group delivery, offline replay and acknowledgement, and account linking. A 60-byte opaque AES-GCM backup passed upload/list/download equality checks; access from another account returned HTTP 403. Authenticated coturn client-to-client relay tests passed over both UDP and TCP, with 10 messages sent and received in each test. These checks do not establish real audio/video call quality or Flutter backup-restore acceptance.

Two real Flutter browser clients exchanged encrypted Czech direct messages in both directions through Azure. Both messages persisted after reloading the public web client. The temporary local test client was stopped and its CORS origin removed after verification.

Current outbound IPv4 addresses for the PostgreSQL firewall: `51.137.102.12`, `51.137.99.214`, `51.136.10.47`, `51.137.55.160`, `20.50.2.95`, `51.144.164.215`. These are the currently reported addresses, not a permanent-IP guarantee; recheck after plan or hosting changes.

## Architecture

- One Linux App Service B1 instance for ASP.NET Core and SignalR, with default HTTPS `*.azurewebsites.net` hostname. Keep one instance because call routing currently uses in-memory state.
- PostgreSQL on the existing server through Npgsql. Connectivity, authentication and encrypted transport are verified; server-certificate verification and backup restoration still need validation.
- Flutter web on Static Web Apps Free, with its actual API URL compiled in and exact CORS origin configured. The [official plan comparison](https://azure.microsoft.com/en-us/pricing/details/app-service/static/) lists 100 GB included bandwidth; exceeding the Free quota stops serving rather than charging overage. Verify applicable quota period and account terms before rollout.
- Small private Blob Storage usage for encrypted history backups, with explicit retention and size limits.
- Authenticated coturn on the existing server if public IP, listener/relay ports, resources and included bandwidth permit it.

No purchased domain, Azure VM, managed PostgreSQL, paid ACR, Application Insights or paid SignalR service is proposed.

## Cost and the USD 20 constraint

The official [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) query for West Europe returned **Linux B1 at USD 0.018/hour: USD 13.14 for 730 hours**. Windows B1 is USD 0.075/hour (USD 54.75 for 730 hours) and is excluded.

The planning target is **USD 14-16/month before tax**, allowing modest Blob usage above the B1 price. Static Web Apps Free is zero within its limits. Existing-server PostgreSQL/coturn are zero incremental cost only if spare capacity and bandwidth are already included.

This is **not a guaranteed USD 20 cap**. Confirm whether that maximum includes tax and existing-server costs. Storage, operations and outbound traffic quotas are not yet implemented; define workload limits and behavior at exhaustion before committing to the ceiling. An [Azure budget alert does not stop consumption or spending](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets).

## Free TURN

Coturn runs on the same existing server as PostgreSQL at `187.127.83.154:3478`, with short-lived credentials issued by the API. Authenticated relay tests passed over UDP and TCP. Allocation quotas, restrictions against private/internal relay destinations, capacity and bandwidth/overage terms still need operational review. Free software does not make traffic free. TURN TLS on restrictive networks needs a verified endpoint and port arrangement.

Fallback: [Metered Open Relay](https://www.metered.ca/tools/openrelay/) advertises **20 GB/month free** and requires an account. Quota-exhaustion behavior and potential overage charges have not been confirmed. Do not describe this as unlimited free TURN or rely on it to enforce the budget until billing behavior is verified.

## Pending decisions and acceptance

1. Configure PostgreSQL server-certificate verification and test database backup restoration. Confirm existing-server resources, included traffic and relay restrictions. Keep credentials out of documentation.
2. Clarify taxes and existing-server costs within USD 20; choose enforceable storage/traffic quotas and exhaustion behavior.
3. Verify real clients against the deployed API, including reconnect, attachments and encrypted backup restore. Review proxy trust and operational monitoring before wider distribution.
4. Verify forced TURN audio/video between separate networks and microphone/camera behavior on the target devices.

Deployment and the API/relay smoke checks above succeeded. They do not establish hosted capacity or completed device acceptance. Apple native validation and Firebase/APNs configuration remain separate release work.
