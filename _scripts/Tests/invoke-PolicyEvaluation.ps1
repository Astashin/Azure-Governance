# Login first with Connect-AzAccount if not using Cloud Shell
#connect-az

$azContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
$authHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $token.AccessToken
}

$subscriptionID = $azContext.Subscription.Id

#try to re-evaluate policies https://docs.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data#on-demand-evaluation-scan
$restUri = "https://management.azure.com/subscriptions/$subscriptionID/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version=2018-07-01-preview"
# Invoke the REST API
Invoke-RestMethod -Uri $restUri -Method POST -Headers $authHeader -Verbose

