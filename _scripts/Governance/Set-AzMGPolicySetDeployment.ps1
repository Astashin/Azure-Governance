[CmdletBinding()]
param (
    [Parameter(Mandatory = $True, HelpMessage = 'Specify local folder containing management group and policies')] [ValidateScript( { Test-Path $_ })] [String]$PoliciesRootFolder,
    [Parameter(Mandatory = $false, HelpMessage = 'Location for the deployment, westeurope by default')] [String]$DeploymentLocation = 'westeurope',
    [Parameter(Mandatory = $false, HelpMessage = 'Optional parameter for temporary management group for test publishing')] [String]$TestManagementGroup
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
function  New-MGPolicySetDefinition {
    param (
        $ManagementGroupName,
        $DeploymentName,
        $DeploymentLocation,
        $PolicySetPath
    )
    
    #check if $ManagementGroupName exists
    if (Test-AzureManagementGroup -ManagementGroupName $ManagementGroupName) {
        # we use API for deployment at Management Group Scope https://docs.microsoft.com/en-us/rest/api/resources/deployments/create-or-update-at-management-group-scope
        #$restUri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupName/providers/Microsoft.Resources/deployments/" + $DeploymentName + '?api-version=2021-04-01'
        #$body = Get-Content $PolicySetPath
        # Invoke the REST API to publish policy ARM to a management group
        <#$body = '{
                "location": "' + $DeploymentLocation + '",
                "properties": {
                "mode": "Incremental",
                "template": ' + $body + ' ,   
                "parameters": { 
                    "ManagementGroupId": {
                        "value" : "/providers/Microsoft.Management/managementgroups/' + $ManagementGroupName + '"
                    }
                }
              }
            }'#>
        #Write-Verbose "Publishing '$DeploymentName' policy set by invoking REST API (PUT) $restUri"
        try { 
            #Invoke-RestMethod -Uri $restUri -Method PUT -Headers $authHeader -Body $body
            New-AzManagementGroupDeployment -ManagementGroupId $ManagementGroupName -Location $DeploymentLocation -TemplateFile $PolicySetPath -TemplateParameterObject @{ManagementGroupId = "/providers/Microsoft.Management/managementgroups/$ManagementGroupName"} -Name $DeploymentName       
        }
        catch {
            write-host "##vso[task.logissue type=error;]$_"
            throw "Error while invoking REST API for $restUri"
            break
        }
        #invoke with GET to acquire deployment status
        #https://docs.microsoft.com/en-us/rest/api/resources/deployments/getatmanagementgroupscope
        Write-Verbose "Waiting until the deployment finishes and returns its state"
  
        #$timeout = new-timespan -Seconds 180
        #$StopWatch = [diagnostics.stopwatch]::StartNew()

        #while (($StopWatch.elapsed -lt $timeout) -and ($DeploymentStatus.ProvisioningState -ne "Succeeded") -and ($DeploymentStatus.ProvisioningState -ne "Failed")) {
            try {
                Write-Verbose "Querying deployment status via REST API (GET) querying $restUri"
                #$DeploymentStatus = Invoke-RestMethod -Uri $restUri -Method GET -Headers $authHeader
                $DeploymentStatus = Get-AzManagementGroupDeployment -Name $DeploymentName -ManagementGroupId $ManagementGroupName
                if ($DeploymentStatus.provisioningState -eq "Failed") {
                    Write-Verbose ("Deployment error message: " + $DeploymentStatus.error.details.message)
                    write-host "##vso[task.logissue type=error;]Policy deployment failed"
                    #Throw "Assignment Failed. See Azure Portal for details."
                    return $false
                }
                if ($DeploymentStatus.provisioningState -eq "Succeeded") {
                    write-host "Policy deployment $DeploymentName succeeded"
                    Write-Verbose ("Deployment time: " + $DeploymentStatus.timestamp + ", duration: " + $DeploymentStatus.duration)
                    return $True
                }
            }
            catch {
                #add error handling
                write-host "##vso[task.logissue type=error;]$_"
                return $False
            }
            #Start-Sleep -Seconds 15
            #Write-Verbose "Sleeping 15 seconds and re-try to query deployment status"
        #}
        return $False      
    }


}

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
write-verbose "Starting script. Checking folders with name '_policies' in $PoliciesRootFolder"
$PoliciesToDeployPath = (Get-ChildItem $PoliciesRootFolder -Recurse | Where-Object { $_.PSIsContainer -and $_.Name.EndsWith('_policies') })

write-verbose ("Discovered path for policies to be published to $ManagementGroupName management group: " + $PoliciesToDeployPath.FullName)

if (!($PoliciesToDeployPath)) {
    write-host "##vso[task.logissue type=error;]$_"
    throw "Policy folder is not found"
}

#do we need to publish it to test MG?
if ($TestManagementGroup) { 
    $ManagementGroupName = $TestManagementGroup
    Write-Verbose "We're in the test deployment mode, deployment will be done to $ManagementGroupName management group"
}

$PoliciesToDeployPath | get-childitem -Directory | ForEach-Object {
    $PolicyName = $_.Name
    $DeploymentName = "policy-$PolicyName-" + [string](Get-Date -Format "yyMMddhhmmss")
    Write-Verbose "Detected policy '$PolicyName'"
    $ManagementGroupName = $_.Parent.Parent.name
    
    # deploy only if policy.json file exists in policy directory
    if (Test-Path -Path  "$($_.FullName)\policy.json") {
        #create policy deployment
        if (New-MGPolicySetDefinition -ManagementGroupName $ManagementGroupName -DeploymentName $DeploymentName -DeploymentLocation $DeploymentLocation -PolicySetPath "$($_.FullName)\policy.json") {
            write-verbose "Policy deployment completed"
        }
    } 
}
Write-Verbose "Script finished working"