#################################################
## New-CMDeploymentGroupForADR.ps1             ##
## Version: 1.0                                ##
## Created By: Nathan Ziehnert                 ##
## E-mail: Nathan.Ziehnert@CatapultSystems.com ##
#################################################
<#
.SYNOPSIS
Creates a new deployment group and then assigns that deployment group to
the selected or designated automatic deployment rule.

.DESCRIPTION
The New-CMDeploymentGroupForADR function uses the CM PowerShell cmdlets
to find the named ADR, creates a new deployment group based on the name
of the ADR and the date that the script was run, and then tells the ADR
to use that deployment group to download updates to. This is useful for
things like SCEP updates - where without regular management, deployment
groups grow rather large and the content is regularly replicated across
WAN links.

.PARAMETER SiteServer
The name of the site server you'll be working on. This defaults to the
$ENV:ComputerName variable.

.PARAMETER SiteCode
The site code of the ConfigMgr site you wish to manage.

.PARAMETER ADRNames
A single ADR name or an array of ADR names. There is no wildcard support.

.PARAMETER DateFormat
Accepts a DateTime format string for the name of the new deployment group.
By default this will be yyyy.MM.dd and is appended to the name of the 
deployment group as well as the folder that the deployment group uses for
source content.

.PARAMETER CreateSinglePackage
A switch that allows you to create a single deployment package to house
all future updates for the named ADRs. This parameter must be used in
conjunction with the DeploymentGroupNameFormat for best results, otherwise
it will use the name of the first named ADR.

.PARAMETER RemoveDate
A switch that allows you to remove the date from the deployment group name
and the deployment group source content folder. Please be aware that if a 
group or folder with the same name already exists, then the script will
just use that existing deployment package.

.PARAMETER DPParentFolder
This is a string to a folder where you want to create new deployment package
source content folders.

.PARAMETER DPName
If you wish to override the default functionality of the script and create
your own deployment package name, you can do so here. Be aware that if a 
package or folder with the same name already exists, then the script will
append a number to the end of the name UNLESS the CreateSinglePackage
switch is used, in which case it will reuse the existing package.

NOTE: This parameter also ignores the date - this is a custom name for the
package.

.EXAMPLE
Create a new deployment package for an ADR named "SCEP Updates" and save the
content to "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\SCEP Updates 2017.10.17\"

New-CMDeploymentGroupForADR.ps1 -ADRNames "SCEP Updates" -DPParentFolder "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\"

.EXAMPLE
Create a new deployment package for an ADR named "SCEP Updates" and save the
content to "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\SCEPUpdates2017.10.17\"

New-CMDeploymentGroupForADR.ps1 -ADRNames "SCEP Updates" -StripSpaces -DPParentFolder "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\"

.EXAMPLE
Create a new deployment package for an ADR named "SCEP Updates" and save the
content to "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\SCEP2017.10.17\"

New-CMDeploymentGroupForADR.ps1 -ADRNames; "SCEP Updates" -DPName "SCEP2017.10.17" -DPParentFolder "\\sccm01.contoso.com\PackageShare\UpdateDeploymentGroups\"

.NOTES
You need the ConfigMgr cmdlets installed on your system for this script to function properly.
#>
[CmdletBinding(SupportsShouldProcess=$True)]
Param(
    [Parameter(Mandatory=$false)]
    [string]$SiteServer = "$ENV:COMPUTERNAME",
    [Parameter(Mandatory=$true)]
    [string]$SiteCode,
    [Parameter(Mandatory=$true)]
    [string[]]$ADRNames,
    [Parameter(Mandatory=$false)]
    [string]$DateFormat="yyyy.MM.dd",
    [Parameter(Mandatory=$false)]
    [switch]$CreateSinglePackage,
    [Parameter(Mandatory=$false)]
    [switch]$RemoveDate,
    [parameter(Mandatory=$true)]
    [string]$DPParentFolder,
    [parameter(Mandatory=$false)]
    [string]$DPName,
    [parameter(Mandatory=$false)]
    [string]$DPGroupName
)

#############################
#Import the PSCmdlet for SCCM
#############################
Write-Verbose "Importing SCCM PowerShell cmdlet"
try{
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" -ErrorAction Stop -Verbose:$false # Import the ConfigurationManager.psd1 module
    Set-Location "$($SiteCode):" 
}
catch{
    Write-Warning "Unable to import the ConfigurationManager.psd1 module... is the admin console installed?"
    Exit
}

####################
#Test DGParentFolder
####################
Write-Verbose "Testing for existence of Deployment Package parent folder."
if(-not (Test-Path $("filesystem::$($DPParentFolder)"))){
    Write-Warning "Unable to reach the Deployment Package parent folder. Did you type it correctly?"
    Exit
}

#######################
#Set constant variables
#######################
$currentDate = Get-Date -Format $DateFormat
Write-Verbose "Current date format set to: $currentDate"
$dpGroup = Get-CMDistributionPointGroup -Name "$DPGroupName"
if($dpGroup -ne $null){
    Write-Verbose "Distribution point group ID: $($dpGroup.GroupID)"
}

###########################################
#Build list of ADR objects from site server
###########################################
Write-Verbose "Building list of ADR objects"
$cmADRs = @()
foreach($ADRName in $ADRNames){
    Write-Verbose "Scanning for ADR: $ADRName"
    if(-not ((Get-CMSoftwareUpdateAutoDeploymentRule -Name "$ADRName" -WarningAction SilentlyContinue -Verbose:$false) -eq $null)){    
        $cmADRs += Get-CMSoftwareUpdateAutoDeploymentRule -Name "$ADRName" -WarningAction SilentlyContinue -Verbose:$false
        Write-Verbose "Found ADR: $ADRName"
    }else{
        Write-Warning "Unable to find the ADR: $ADRName... this will be skipped"
    }
    if($cmADRs.Count -eq 0){
        Write-Warning "No ADRs found... exiting."
        Exit
    }
}

##############################################
#Check for existing deployment package and set 
#the hash table for DG to ADR relationships.
#Create new deployment packages if necessary
##############################################
Write-Verbose "Checking for existing deployment packages."
$cmDPtoADRTable = @()
if($CreateSinglePackage){
    Write-Verbose "Create Single Package selected..."
    if($DPName -eq "") { 
        Write-Verbose "Standard naming selected..."
        $DPName = $ADRNames[0]
        if(-not $RemoveDate){
            $DPName = "$DPName $currentDate"
        }
    }else{
        Write-Verbose "Custom naming selected..."
    }
    if((Get-CMSoftwareUpdateDeploymentPackage -Name "$DPName" -Verbose:$false) -ne $null){
        $cmDP = Get-CMSoftwareUpdateDeploymentPackage -Name "$DPName" -Verbose:$false
        Write-Verbose "Found Deployment Package with name `"$DPName`""
        Write-Verbose "Adding ADRs to hash table to point to `"$DPName`""
    }else{
        Write-Verbose "Unable to find deployment... checking folder structure..."
        $i = $null
        while(Test-Path $("filesystem::$($DPParentFolder)\$DPName$i")){
            $i++
        }
        Write-Verbose "Creating package folder..."
        if($pscmdlet.ShouldProcess("$DPParentFolder","Create Folder $DPName$i")){
            if(-not (Test-Path "filesystem::$($DPParentFolder)\$DPName$i")){
                New-Item "filesystem::$($DPParentFolder)\$DPName$i" -Type Directory | out-null
            }
            $DPName = "$DPName$i"
        }
        Write-Verbose "Creating deployment package..."
        if($pscmdlet.ShouldProcess("$SiteServer","Create Deployment Package $DPName")){
            $cmDP = New-CMSoftwareUpdateDeploymentPackage -Name $DPName -Path "$($DPParentFolder)\$DPName"
            Write-Warning "Cmdlets and WMI don't allow for enabling Binary Differential Replication. This will have to be done manually if you wish."
            if($DPGroupName){
                Write-Verbose "Adding Deployment Package to Distribution Point group $DPGroupName"
                (Get-WmiObject -Namespace "root\sms\site_$SiteCode" -ComputerName "$SiteServer" -Class "SMS_DistributionPointGroup" -Filter "Name='$($DPGroupName)'").AddPackages($cmDP.PackageID) | out-null
            }
        }
    }
    foreach($cmADR in $cmADRs){
        $cmDPtoADRHash = @{}
        $cmDPtoADRHash.Add("ADR",$cmADR)
        $cmDPtoADRHash.Add("DP",$cmDP)
        $cmDPtoADRTable += [pscustomobject]$cmDPtoADRHash
    }
}
else{
    Write-Verbose "Creating a separate package for each ADR"
    if($DPName -eq "") { 
        Write-Verbose "Standard naming selected..."
        foreach($cmADR in $cmADRs){
            $cmDP = $null
            $DPName = "$($cmADR.Name)"
            if(-not $RemoveDate){
                $DPName = "$DPName $currentDate"
            }
            if((Get-CMSoftwareUpdateDeploymentPackage -Name "$DPName" -Verbose:$false) -ne $null){
                $cmDP = Get-CMSoftwareUpdateDeploymentPackage -Name "$DPName" -Verbose:$false
                Write-Verbose "Found Deployment Package with name `"$DPName`""
                Write-Verbose "Adding ADRs to hash table to point to `"$DPName`""
            }else{
                Write-Verbose "No existing deployment package... checking folder structure..."
                Write-Verbose "Creating package folder..."
                if($pscmdlet.ShouldProcess("$DPParentFolder","Create Folder $DPName")){
                    if(-not (Test-Path "filesystem::$($DPParentFolder)\$DPName")){
                        New-Item "filesystem::$($DPParentFolder)\$DPName" -Type Directory | out-null
                    }
                }
                Write-Verbose "Creating deployment package..."
                if($pscmdlet.ShouldProcess("$SiteServer","Create Deployment Package $DPName")){
                    $cmDP = New-CMSoftwareUpdateDeploymentPackage -Name $DPName -Path "$($DPParentFolder)\$DPName"
                    Write-Warning "Cmdlets and WMI don't allow for enabling Binary Differential Replication. This will have to be done manually if you wish."
                    if($DPGroupName){
                        Write-Verbose "Adding Deployment Package to Distribution Point group $DPGroupName"
                        (Get-WmiObject -Namespace "root\sms\site_$SiteCode" -ComputerName "$SiteServer" -Class "SMS_DistributionPointGroup" -Filter "Name='$($DPGroupName)'").AddPackages($cmDP.PackageID) | out-null
                    }
                }
            }
            $cmDPtoADRHash = @{}
            $cmDPtoADRHash.Add("ADR",$cmADR)
            $cmDPtoADRHash.Add("DP",$cmDP)
            $cmDPtoADRTable += [pscustomobject]$cmDPtoADRHash
        }
    }
}

#####################################
#Set the ADRs to point to the new DPs
#####################################
foreach($cmDPtoADR in $cmDPtoADRTable){
    if($pscmdlet.ShouldProcess("$($cmDPtoADR.ADR.Name)", "Setting Deployment Package $($cmDPtoADR.DP.Name)")){
        [wmi]$AutoDeployment = (Get-WmiObject -Class SMS_AutoDeployment -Namespace root/SMS/site_$($SiteCode) -ComputerName "$SiteServer" | Where-Object -FilterScript {$_.Name -eq $($cmDPtoADR.ADR.Name)}).__PATH
        [xml]$ContentTemplateXML = $AutoDeployment.ContentTemplate
        $ContentTemplateXML.ContentActionXML.PackageId = $($cmDPtoADR.DP.PackageID)
        $AutoDeployment.ContentTemplate = $ContentTemplateXML.OuterXML
        $AutoDeployment.Put() | out-null
    }
}
