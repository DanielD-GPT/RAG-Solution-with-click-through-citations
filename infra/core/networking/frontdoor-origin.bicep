metadata description = 'Phase 2 of the Front Door + WAF setup. Configures the origin group, origin, and route on a Front Door profile that already exists (created by frontdoor-waf.bicep). Deploy this AFTER the application backend so that originHostName resolves to the real App Service / Container App FQDN.'

@description('Name of the existing Front Door profile.')
param profileName string

@description('Name of the existing AFD endpoint on the profile.')
param endpointName string

@description('Origin hostname (App Service defaultHostName or Container App FQDN).')
param originHostName string

@description('Origin host header. Defaults to the origin hostname.')
param originHostHeader string = originHostName

@description('Health probe path. Backend must return 2xx for / via HEAD; override to /healthz if you have a dedicated probe.')
param probePath string = '/'

resource profile 'Microsoft.Cdn/profiles@2024-02-01' existing = {
  name: profileName
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' existing = {
  parent: profile
  name: endpointName
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'default-origin-group'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: probePath
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 60
    }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: originGroup
  name: 'default-origin'
  properties: {
    hostName: originHostName
    httpsPort: 443
    originHostHeader: originHostHeader
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'default-route'
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [ 'Https' ]
    patternsToMatch: [ '/*' ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    origin
  ]
}
