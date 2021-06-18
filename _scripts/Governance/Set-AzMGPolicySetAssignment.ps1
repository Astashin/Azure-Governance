[CmdletBinding()]
param (
    [Parameter(Mandatory = $True, HelpMessage = 'Specify local folder containing management group and policies')] [ValidateScript( { Test-Path $_ })] [String]$PoliciesRootFolder,
    [Parameter(Mandatory = $false, HelpMessage = 'Location for the deployment, westeurope by default')] [String]$DeploymentLocation = 'westeurope',
    [Parameter(Mandatory = $false, HelpMessage = 'Optional parameter for temporary management group for tests')] [String]$TestManagementGroup
)

function Test-AzureManagementGroup {
    #function checks if $ManagementGroupName exists
    param (
        [Parameter(Mandatory = $True)] [String]$ManagementGroupName
    )
    try {
        if (!(Get-AzManagementGroup -GroupName $ManagementGroupName)) {
            write-host "##vso[task.logissue type=error;]$_"
            Write-Verbose  "$ManagementGroupName not found"
            return $false
        }
        else {
            return $True
        }
    }
    catch {
        write-host "##vso[task.logissue type=error;]$_"
        Write-Verbose "Error querying $ManagementGroupName management group"
        return $false
    }
}

function  New-MGPolicySetAssignment {
    [CmdletBinding()]
    param (
        $ManagementGroupName,
        $PolicyDefinitionId,
        $PolicySetAssignmentName,
        $AssignmentPath
    )
    
    if (Test-AzureManagementGroup -ManagementGroupName $ManagementGroupName) {
        # we use API for assignment at Management Group Scope https://docs.microsoft.com/en-us/rest/api/policy/policy-assignments/create
        $restUri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupName/providers/Microsoft.Authorization/policyAssignments/$PolicySetAssignmentName" + '?api-version=2020-09-01'
        $body = Get-Content $AssignmentPath -Raw  | ConvertFrom-Json
        
        #replace or add policyDefinitionId in assignment JSON to match exact management group
        $body.properties | Add-Member -Name policyDefinitionId -Value $PolicyDefinitionId -MemberType NoteProperty -Force
        $body = $body | convertto-json -Depth 50  

        # Invoke the REST API to publish policy ARM to a management group
        Write-Verbose "Assigning '$PolicySetAssignmentName' policy set by invoking REST API (PUT) to $restUri"

        try {
            Invoke-RestMethod -Uri $restUri -Method PUT -Headers $authHeader -Body $body
            return $True
        }
        catch {
            write-host "##vso[task.logissue type=error;]$_"
            Write-Verbose "Error while invoking REST API $restUri"
            return $false
        } 
    }
  
}

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
write-verbose "Starting script. Checking folders with name '_policies' in $PoliciesRootFolder"
$PoliciesPath = (Get-ChildItem $PoliciesRootFolder -Recurse | Where-Object { $_.PSIsContainer -and $_.Name.EndsWith('_policies') })


write-verbose ("Discovered path for policies: " + $PoliciesPath.FullName)

if (!($PoliciesPath)) {
    write-host "##vso[task.logissue type=error;]$_"
    throw "Policy folder is not found"
}

#standard way to extract authentication token from current session and add it to Bearer auth. HTTP header
Write-Verbose "Trying to get authentication token for REST API request"
try {
    $azContext = Get-AzContext
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
    $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
    $authHeader = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $token.AccessToken
    }
    Write-Verbose ("Authentication token acquired for " + $azContext.Name)
}
catch {
    write-host "##vso[task.logissue type=error;]$_"
    throw "Unable to get authentication token"
}

#$PoliciesPath | get-childitem -File | ForEach-Object {
$PoliciesPath | get-childitem -Directory | ForEach-Object {
    $PolicySetName = $_.Name
    Write-Verbose "Detected policy set '$PolicySetName'"
   
    # deploy only if policy.json file exists in policy directory
    if (Test-Path -Path  "$($_.FullName)\policy.json") {
        #create policy deployment
        write-verbose "Looking for assignment.*.json files in '$($_.Name)' policy folder"
        #search for assignment.* JSON files in policy folder
        Get-ChildItem -Path $_.fullname | Where-Object { $_.name -like "assignment.*.json" } | ForEach-Object {
            #assigning policy set using REST API and assignment file content 
            write-verbose "Found assignment for $($_.Name) policy. Performing assignment for management group $($_.basename.Split("assignment.", [System.StringSplitOptions]::RemoveEmptyEntries)[0])"
            
            $DefinitionManagementGroupName = $_.directory.Parent.Parent.name
            $AssignmentManagementGroupName = ($_.basename.Split("assignment.", [System.StringSplitOptions]::RemoveEmptyEntries)[0])
            #Policy assignment length is limited to 24 characters
            $PolicySetAssignmentName = "pol-assign-$AssignmentManagementGroupName-$PolicySetName"
            $PolicySetAssignmentName = $PolicySetAssignmentName.subString(0, [System.Math]::Min(24, $PolicySetAssignmentName.Length))

            #do we need to publish it to test MG?
            if ($TestManagementGroup) { 
                $AssignmentManagementGroupName = $TestManagementGroup
                Write-Verbose "We're in the test mode, assignment will be done to $AssignmentManagementGroupName management group"
            }    
            try {
                $PolicySetSetAssignment = New-MGPolicySetAssignment -PolicySetAssignmentName $PolicySetAssignmentName -ManagementGroupName $AssignmentManagementGroupName -PolicyDefinitionId "/providers/Microsoft.Management/managementGroups/$DefinitionManagementGroupName/providers/Microsoft.Authorization/policySetDefinitions/$PolicySetName" -AssignmentPath $_.fullname
                # check if managed idetity is required for policy assignment
                if ($PolicySetSetAssignment) {
                    Write-Verbose "Policy set assignment '$PolicySetAssignmentName' completed. Checking if system assigned managed identities should be granted Contributor role"
                }
                if ($PolicySetSetAssignment.identity.type -eq 'SystemAssigned') {
                    # it takes some time for managed identity to register in Azure AD tenant
                    Start-Sleep -Seconds 15
                    # for simplicity we assign Contributor role without parsing roleDefinitionIds in policy JSON
                    New-AzRoleAssignment -Scope "/providers/microsoft.management/managementGroups/$AssignmentManagementGroupName" -ObjectId $PolicySetSetAssignment.identity.PrincipalId -RoleDefinitionId 'b24988ac-6180-42a0-ab88-20f7382dd24c' -ErrorAction SilentlyContinue
                    Write-Verbose "Role assignment for system assigned managed identity with id $($PolicySetSetAssignment.identity.PrincipalId) completed for management group '$AssignmentManagementGroupName'"
                }
            }
            catch {
                Write-Verbose "Unable to perform an assignment for '$PolicySetName'"
                write-host "##vso[task.logissue type=error;]$_"
            }
        }

        
    }
}
Write-Verbose "Script finished working"