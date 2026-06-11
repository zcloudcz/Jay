// ---------------------------------------------------------------------------
// main.bicep — Azure infrastructure for CallType API
// ---------------------------------------------------------------------------
// Deploys: Log Analytics, Container App Environment, Container App (API),
// Azure Database for PostgreSQL Flexible Server, and a Storage Account
// for encrypted backups.
//
// Usage:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters.dev.json
// ---------------------------------------------------------------------------

// --- Parameters -------------------------------------------------------------

@description('Environment name — used as suffix for all resource names')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Container image to deploy (e.g. myacr.azurecr.io/calltype-api:latest)')
param containerImage string

@description('PostgreSQL administrator login name')
param pgAdminLogin string = 'calltypeadmin'

@description('PostgreSQL administrator password')
@secure()
param pgAdminPassword string

@description('JWT signing secret (>= 32 chars)')
@secure()
param jwtSecret string

@description('TURN shared secret for WebRTC credential generation')
@secure()
param turnSharedSecret string

@description('Firebase service account JSON for FCM HTTP v1 push (optional, empty = push disabled)')
@secure()
param fcmServiceAccountJson string = ''

@description('Custom domain for the API (optional, empty = use default ACA domain)')
param customDomain string = ''

// --- Variables --------------------------------------------------------------
// Naming convention: calltype-{resource}-{env} for readability in Azure Portal.

var suffix = 'calltype-${environment}'
var logAnalyticsName = 'log-${suffix}'
var acaEnvName = 'acaenv-${suffix}'
var acaAppName = 'api-${suffix}'
var pgServerName = 'pg-${suffix}'
var pgDatabaseName = 'calltype'
var storageName = replace('st${suffix}', '-', '') // Storage accounts don't allow hyphens

// --- Log Analytics Workspace ------------------------------------------------
// Required by Container App Environment for log aggregation. Logs from the API
// container (stdout/stderr) are automatically routed here.

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    // 30-day retention is the free tier default — sufficient for dev,
    // increase for prod via parameter override if needed.
    retentionInDays: 30
  }
}

// --- Container App Environment ----------------------------------------------
// Shared environment for all Container Apps in this deployment. Provides
// networking, logging, and Dapr (if needed later).

resource acaEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// --- Container App (API) ----------------------------------------------------
// Runs the CallType.Api Docker image. SignalR requires sticky sessions so
// WebSocket connections stay on the same replica.

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: acaAppName
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      // Secrets are stored encrypted in ACA — not in the container image.
      // Referenced by name in the env block below via secretRef.
      secrets: [
        {
          name: 'jwt-secret'
          value: jwtSecret
        }
        {
          name: 'turn-secret'
          value: turnSharedSecret
        }
        {
          // Whole Firebase service account JSON as one secret — the API parses
          // client_email/private_key/project_id out of it. Empty = push disabled.
          name: 'fcm-service-account'
          value: fcmServiceAccountJson
        }
      ]
      // External ingress — the API is publicly accessible.
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        // Sticky sessions required for SignalR — WebSocket connections must
        // stay on the same replica for the connection lifetime.
        stickySessions: {
          affinity: 'sticky'
        }
        // Custom domain binding (if provided).
        customDomains: customDomain != '' ? [
          {
            name: customDomain
            bindingType: 'Disabled' // Set to 'SniEnabled' after cert is configured
          }
        ] : []
      }
    }
    template: {
      containers: [
        {
          name: 'calltype-api'
          image: containerImage
          resources: {
            // Start small for dev, scale up for prod via parameter override.
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://+:8080'
            }
            {
              // EF Core connection string pointing at the PostgreSQL Flexible Server.
              name: 'ConnectionStrings__DefaultConnection'
              value: 'Host=${pgServer.properties.fullyQualifiedDomainName};Port=5432;Database=${pgDatabaseName};Username=${pgAdminLogin};Password=${pgAdminPassword};Ssl Mode=Require'
            }
            {
              // Azure Blob Storage connection string for encrypted backups.
              name: 'ConnectionStrings__BlobStorage'
              value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
            }
            {
              name: 'Jwt__Secret'
              secretRef: 'jwt-secret'
            }
            {
              name: 'Jwt__Issuer'
              value: 'CallType.Api'
            }
            {
              name: 'Turn__SharedSecret'
              secretRef: 'turn-secret'
            }
            {
              name: 'Push__FcmServiceAccountJson'
              secretRef: 'fcm-service-account'
            }
          ]
        }
      ]
      scale: {
        minReplicas: environment == 'prod' ? 1 : 0
        maxReplicas: environment == 'prod' ? 5 : 2
      }
    }
  }
}

// --- Azure Database for PostgreSQL Flexible Server --------------------------
// Fully managed PostgreSQL — no VM patching, automated backups, point-in-time
// restore. Flexible Server is the recommended tier (Single Server is deprecated).

resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: pgServerName
  location: location
  sku: {
    // Burstable B1ms (1 vCore, 2 GiB RAM) — cheapest option for dev/staging.
    // For prod, use 'Standard_D2ds_v4' or higher.
    name: environment == 'prod' ? 'Standard_D2ds_v4' : 'Standard_B1ms'
    tier: environment == 'prod' ? 'GeneralPurpose' : 'Burstable'
  }
  properties: {
    version: '17'
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgAdminPassword
    storage: {
      storageSizeGB: environment == 'prod' ? 64 : 32
    }
    backup: {
      backupRetentionDays: environment == 'prod' ? 35 : 7
      geoRedundantBackup: environment == 'prod' ? 'Enabled' : 'Disabled'
    }
    highAvailability: {
      mode: environment == 'prod' ? 'ZoneRedundant' : 'Disabled'
    }
  }
}

// Create the application database on the PostgreSQL server.
resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pgServer
  name: pgDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Allow Azure services (including Container Apps) to connect to PostgreSQL.
// In production, restrict this to the ACA subnet via VNet integration.
resource pgFirewallAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pgServer
  name: 'AllowAzureServices'
  properties: {
    // 0.0.0.0 is the Azure-convention for "allow Azure services."
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// --- Storage Account --------------------------------------------------------
// Stores encrypted backup blobs. The API uploads/downloads via BlobServiceClient.
// Server-side encryption at rest is enabled by default (Microsoft-managed keys).

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    // LRS for dev (cheapest), GRS for prod (geo-redundant backups).
    name: environment == 'prod' ? 'Standard_GRS' : 'Standard_LRS'
  }
  properties: {
    // TLS 1.2 minimum — no reason to support older versions.
    minimumTlsVersion: 'TLS1_2'
    // Disable public blob access — backups are private, accessed only via
    // the API with shared key auth.
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// Pre-create the backups container so the API doesn't need CreateIfNotExists
// permissions in production (principle of least privilege).
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'backups'
  properties: {
    publicAccess: 'None'
  }
}

// --- Outputs ----------------------------------------------------------------
// Useful for CI/CD scripts that need resource names/URLs after deployment.

output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output pgServerFqdn string = pgServer.properties.fullyQualifiedDomainName
output storageAccountName string = storageAccount.name
