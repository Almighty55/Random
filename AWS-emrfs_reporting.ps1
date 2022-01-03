<# 
Author: Adam Alaraj
Purpose: Script gathers the active emr cluster ID, then pulls the emrfs roles to group mapping.
From there it gathers the associated members of each group as well as the json policy of each role.

This script leverages various packages listed below:
* Install-Module AWS.Tools.Installer -SkipPublisherCheck ; Update-AWSToolsModule -SkipPublisherCheck
* Install-Module -Name AWS.Tools.ElasticMapReduce -SkipPublisherCheck
* Install-Module -Name AWS.Tools.IdentityManagement
* msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
Use powershell 7
* Install-WindowsFeature -Name ActiveDirectory
 #>
 
function Get-DestinationPath {
    $filename = "EMRFS_Mappings_"+(Get-Date -Format 'MM/dd/yyyy')+".csv"
    $filename = $filename.Split([System.IO.Path]::GetInvalidFileNameChars()) -join '_'
    $path = "C:\Users\$env:USERNAME\Documents\csvReports\" 
    if (!(Test-Path -Path $path)){
        New-Item -Path $path -ItemType Directory | Out-Null
    }
    $path = ($path+$filename)
    return $path;
}
function Get-EMRRolesMapping {    
    # TODO: handle multiple active clusters 
    # Couldn't figure out a way to properly get this info through the ps module, but still works fine
    $clusterID = aws emr list-clusters --active | ConvertFrom-Json
    $clusterID = $clusterID.Clusters.id
    $cluster = Get-EMRCluster $clusterID
    # This grabs the security configuration that is applied to the cluster since multiple can be in AWS
    $SecurityConfiguration = $cluster.SecurityConfiguration
    # here we get the json output of the security configuration
    $json = Get-EMRSecurityConfiguration -name $SecurityConfiguration | Select-Object SecurityConfiguration -ExpandProperty SecurityConfiguration
    #convert it from json so we can manipulate it within powershell
    $converted = $json | ConvertFrom-Json
    #this is the direct mapping that shows AD groups applied to which role
    $roleMappings = $converted.AuthorizationConfiguration.EmrFsConfiguration.RoleMappings
    #*! Do we need to worry about anything other than groups in the role mappings? users etc?
    $roleMappings = $converted.AuthorizationConfiguration.EmrFsConfiguration.RoleMappings | Where-Object {$_.IdentifierType -eq "Group"}
    return $roleMappings;
}

# Run that young function
$roleMappings = Get-EMRRolesMapping

foreach ($role in $roleMappings){
    # get index of current item to add members to that array index
    $index = [array]::IndexOf($roleMappings, $role)
    #list of AD groups
    $groups = $roleMappings[$index].identifiers
    # convert from array to string for pretty output
    $groupsPretty = $groups -join ", " | Out-String -NoNewline
    $roleMappings[$index] | Add-Member -MemberType NoteProperty -Name Identifiers -Value $groupsPretty -Force
    # Get the proper format of the role names
    $roleName = $role.role -split "/" | Select-Object -Last 1
    $roleMappings[$index] | Add-Member -MemberType NoteProperty -Name Role -Value $roleName -Force
    foreach ($group in $groups){
        try{ # condense list of group members into one object
            $names = @(Get-ADGroupMember -Identity $group | Select-Object name -ExpandProperty name) 
            if ($names) {
                # convert from array to string for pretty output
                $names = $names -join ", " | Out-String -NoNewline
                $roleMappings[$index] | Add-Member -MemberType NoteProperty -Name Members -Value $names -Force
            }
        }
        catch{ 
            if ($PSItem.Exception.Message -like "*Cannot find an object with identity:*"){ # in the event no AD group is found write an Alert
                Write-Host -BackgroundColor Black -ForegroundColor Yellow "ALERT: *** AD group $group was not found ***"
                # keep track how how many groups are not found
                $tracker++
            }
            else { # in the event there was a real error spit it out
                Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: *** AD group $group errored out ***"
                $_
            }
        }
    }
}
Write-Host -BackgroundColor Black -ForegroundColor Green "NOTE: A total of $tracker groups were not found"
# TODO: handle multiple managed policies and/or multiple inline policies
# TODO: figure out why the policy jumbles S3 buckets. I think it's because of terraform either add/remove a whitespace from the template.
foreach ($roleName in $roleMappings.role) {
    # get index of current item to add members to that array index
    $index = [array]::IndexOf($roleMappings.role, $roleName)
    # Get the managed policies attached to the emrfs role
    $managedPolicies = Get-IAMAttachedRolePolicyList -RoleName $roleName 
    if($managedPolicies){ # only run the below if managed policies are found
        # Get the latest version of the policy
        $versions = Get-IAMPolicyVersionList -PolicyArn $managedPolicies.PolicyArn
        $versionID = $versions | Sort-Object CreateDate  | Select-Object -last 1
        # Get the actual Json of the policy
        $results = Get-IAMPolicyVersion -PolicyArn $managedPolicies.PolicyArn -VersionID $versionID.VersionID
        # decode to readable Json format
        $managedPolicy = [System.Web.HttpUtility]::UrlDecode($results.Document)
        #this would store the policy into a PS object and then you can pull certain things out of it if needed
        #$managedPolicy = $managedPolicy | ConvertFrom-Json        
    }

    # Get the inline policies attached to the emrfs role
    $inlinePolicy = Get-IAMRolePolicyList -RoleName $roleName
    if($inlinePolicy){ # only run the below if inline policies are found
        $results = Get-IAMRolePolicy -RoleName $roleName -PolicyName $inlinePolicy 
        $inlinePolicy = [System.Web.HttpUtility]::UrlDecode($results.PolicyDocument)
        #this would store the policy into a PS object and then you can pull certain things out of it if needed
        #$inlinePolicy = $inlinePolicy | ConvertFrom-Json
    }
    $roleMappings[$index] | Add-Member -MemberType NoteProperty -Name ManagedPolicy -Value $managedPolicy
    $roleMappings[$index] | Add-Member -MemberType NoteProperty -Name InlinePolicy -Value $inlinePolicy
}

# TODO: See if the csv output is good enough or if it should spit out json to vscode for syntax highlighting
# Copy the custom object
$roleMappingsCSV = $roleMappings.PsObject.Copy()
# Rename the properties for a better output
$roleMappingsCSV = $roleMappingsCSV | Select-Object @{N='IAM_Role'; E={$_.Role}},`
@{N='Basis_Type'; E={$_.IdentifierType}},`
@{N='Basis_for_Access'; E={$_.Identifiers}},`
@{N='Members'; E={$_.Members}},`
@{N='Managed_Policy'; E={$_.ManagedPolicy}},`
@{N='Inline_Policy'; E={$_.InlinePolicy}}

$roleMappingsCSV | Export-CSV -NoTypeInformation -Force -Path (Get-DestinationPath)
Write-Host "Report was saved here: "(Get-DestinationPath)