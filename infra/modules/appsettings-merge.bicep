// Adds NON-SECRET app settings to an existing web app without touching the ones already there.
//
// WHY a module with an explicit merge: an ARM PUT on sites/config/appsettings replaces the WHOLE
// collection (see docs/ops/beta-infrastructure.md). Writing only our keys would wipe Jwt__Secret,
// connection strings, CORS origins and every other secret the owner set by hand. The caller passes
// the current collection (read with list() at deployment time) and this module writes
//   union(defaults, current)
// — in Bicep's union() the LAST object wins, so every value that already exists is kept exactly as
// it is and only MISSING keys are added. An owner who tuned a value in the portal is never
// overridden by a re-deploy. The flip side (documented in beta-infrastructure.md): changing a
// default here does not change a value that is already set; that needs `az webapp config
// appsettings set` or deleting the key first.
//
// Secrets never go through this module: no Push__Apns__PrivateKeyP8, Jwt__Secret, connection
// strings, TURN tokens. They are set by the owner (docs/ops/beta-infrastructure.md, table
// "App settings").

@description('Existing web app name.')
param webAppName string

@description('Current app settings of the web app, as returned by list(.../config/appsettings).properties.')
param currentAppSettings object

@description('Non-secret defaults to add when missing. Values must be strings (App Service stores strings).')
param defaultAppSettings object

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
  name: 'appsettings'
  properties: union(defaultAppSettings, currentAppSettings)
}

output appliedKeys array = objectKeys(defaultAppSettings)
