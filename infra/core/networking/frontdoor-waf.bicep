metadata description = 'Phase 1 of the Front Door + WAF setup. Provisions the Front Door Premium profile, AFD endpoint, WAF policy, and the security-policy association. NO origin is configured here — the origin and route are added by frontdoor-origin.bicep after the application is deployed. This split exists to break the chicken-and-egg dependency between the app (which needs frontDoorId from this module) and Front Door (which needs the app hostname for its origin).'

@description('Profile name. Must be globally unique.')
param name string

@description('Tags applied to the Front Door profile and policy.')
param tags object = {}

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
output profileName string = profile.name
output endpointName string = endpoint.name
output endpointHostName string = endpoint.properties.hostName
output wafPolicyId string = policy.id
