metadata description = 'Provisions an Azure Front Door Premium profile with a managed WAF (prevention mode) in front of the application origin. Front Door enforces TLS, geo-filtering, and rate-limit / OWASP rules, and stamps an X-Azure-FDID header that the backend MUST validate so the origin cannot be hit directly.'

@description('Profile name. Must be globally unique.')
param name string

@description('Tags applied to the Front Door profile and policy.')
param tags object = {}

@description('Backend origin hostname (e.g. mywebapp.azurewebsites.net or aca app FQDN).')
param originHostName string

@description('Backend origin host header. Defaults to the origin hostname.')
param originHostHeader string = originHostName

@description('Allowed country codes (ISO 3166-1 alpha-2). Empty array = no geo filter.')
param allowedCountries array = []

@description('Per-IP request limit per minute. Default 600 (10 req/sec sustained).')
@minValue(10)
@maxValue(20000)
param rateLimitThresholdPerMinute int = 600

@description('WAF mode. Use Prevention in production; Detection only for tuning runs.')
@allowed([ 'Prevention', 'Detection' ])
param wafMode string = 'Prevention'

var policyName = '${replace(name, '-', '')}wafpolicy'

resource policy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: policyName
  location: 'Global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: wafMode
      requestBodyCheck: 'Enabled'
    }
    customRules: {
      rules: concat(
        [
          {
            name: 'RateLimitPerIp'
            priority: 100
            ruleType: 'RateLimitRule'
            rateLimitDurationInMinutes: 1
            rateLimitThreshold: rateLimitThresholdPerMinute
            matchConditions: [
              {
                matchVariable: 'RemoteAddr'
                operator: 'IPMatch'
                negationConditon: true
                matchValue: [ '255.255.255.255/32' ]
              }
            ]
            action: 'Block'
          }
        ],
        !empty(allowedCountries) ? [
          {
            name: 'GeoAllowList'
            priority: 200
            ruleType: 'MatchRule'
            matchConditions: [
              {
                matchVariable: 'RemoteAddr'
                operator: 'GeoMatch'
                negationConditon: true
                matchValue: allowedCountries
              }
            ]
            action: 'Block'
          }
        ] : []
      )
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
        }
      ]
    }
  }
}

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: name
  location: 'Global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: '${name}-ep'
  location: 'Global'
  properties: {
    enabledState: 'Enabled'
  }
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
      probePath: '/'
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

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: profile
  name: 'default-security-policy'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: policy.id
      }
      associations: [
        {
          domains: [
            {
              id: endpoint.id
            }
          ]
          patternsToMatch: [ '/*' ]
        }
      ]
    }
  }
}

output frontDoorId string = profile.properties.frontDoorId
output endpointHostName string = endpoint.properties.hostName
output wafPolicyId string = policy.id
