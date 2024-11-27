# This script will automatically rename an AD/AAD-bound Windows computer to the machine's serial number based on the following command:
# MG ON 11/27/24 --> NEED TO PRETTIFY THE OUTPUTS AND ADD VERSIONING INFO (COMMENTED OUT)

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $False)] [string] $Prefix = "",
    [switch] $TestMode,  # -T for Test Mode
    [Alias("TestFlag")] [switch] $t # Renamed alias for Test Mode
)

# Function to log and exit
function Log-Exit {
    param([string]$message, [int]$exitCode = 0)
    Write-Host $message
    Stop-Transcript
    Exit $exitCode
}

# Function to retrieve the logged-on user's temp directory
function Get-LoggedOnUserTemp {
    try {
        $LoggedOnUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
        if ($LoggedOnUser -and $LoggedOnUser -match "\\") {
            $UserName = $LoggedOnUser.Split("\")[-1]
            $UserProfilePath = Join-Path -Path "C:\Users" -ChildPath $UserName
            $TempPath = Join-Path -Path $UserProfilePath -ChildPath "AppData\Local\Temp"
            if (Test-Path $TempPath) {
                return $TempPath
            } else {
                throw "Temp path does not exist for user: $UserName"
            }
        } else {
            Write-Warning "No logged-on user found, using SYSTEM temp directory."
            return "C:\Windows\Temp"
        }
    } catch {
        Write-Warning "Error resolving logged-on user's temp directory: $($_.Exception.Message)"
        return "C:\Windows\Temp"
    }
}

# Function to retrieve and validate the serial number
function Get-SerialNumber {
    try {
        # Detect if the system is a virtual machine
        $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure
        $isVirtualMachine = ($systemEnclosure.ChassisTypes -contains 3 -or
                             $systemEnclosure.ChassisTypes -contains 4)
        if ($isVirtualMachine) {
            Write-Host "Virtual machine detected. Serial number retrieval may differ."
        }

        # Get the serial number
        $serialNumber = (Get-CimInstance -ClassName Win32_BIOS | Select-Object -ExpandProperty SerialNumber)

        # Fallback for invalid serial numbers
        if ($serialNumber -eq $null -or $serialNumber -match '^[ ]*$') {
            $serialNumber = "UnknownSerial"
        }

        # Replace spaces with hyphens and remove invalid characters
        $serialNumber = $serialNumber -replace '[^a-zA-Z0-9-]', ''
        $serialNumber = $serialNumber -replace ' ', '-'

        return $serialNumber
    } catch {
        Write-Host "Error retrieving serial number: $($_.Exception.Message)"
        return "InvalidSerial"
    }
}

#THE FUN BEGINS!!!!!!!!!!!

# Heads up - test mode!
if ($TestMode) {
    Write-Host "Script is being run in test mode."
}

# Opening credits. Star Wars???
Write-Host ""
Write-Host "RenameComputer v1.5"
Write-Host "Based on version 1.3 (latest) of Michael Niehaus' RenameComputer.ps1 script."
Write-Host "EXCELLENT write-up on it on his blog, here: https://oofhours.com/2020/05/19/renaming-autopilot-deployed-hybrid-azure-ad-join-devices/"
Write-Host ""
Write-Host "Script is running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host ""


# Combine TestMode flags (-t and -T)
$TestMode = $TestMode -or $t

# Resolve the logged-on user's temp directory and initialize transcript
$LoggedOnUserTemp = Get-LoggedOnUserTemp
try {
    $LogFilePath = "C:\Windows\Temp\RenameComputer.log"
    if ($LoggedOnUserTemp -ne "C:\Windows\Temp") {
        $LogFilePath = Join-Path -Path $LoggedOnUserTemp -ChildPath "RenameComputer.log"
    }
    Start-Transcript -Path $LogFilePath -Append
} catch {
    Write-Host "Failed to start transcript logging. Error: $($_.Exception.Message)"
    Write-Host ""
}

# Check if AD or AAD joined
$isAD = $false
$isAAD = $false
$tenantID = $null
try {
    $details = Get-ComputerInfo
    if ($details.CsPartOfDomain) {
        Write-Host "Device is joined to AD domain: $($details.CsDomain)"
        $isAD = $true
    } elseif (Test-Path "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo") {
        $subKey = Get-Item "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo"
        $tenantID = ($subKey.GetSubKeyNames() | ForEach-Object {
            (Get-ItemProperty "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo\$_").TenantId
        }) -join ", "
        if ($tenantID) {
            Write-Host "Device is joined to AAD tenant: $tenantID"
            $isAAD = $true
        } else {
            Write-Host "Not part of a domain or AAD, in a workgroup."
        }
    }
} catch {
    Log-Exit "Error: Failed to detect AD or AAD domain membership. $_" 1
}
Write-Host ""
# Resolve the serial number
$serialNumber = Get-SerialNumber
$newName = "$serialNumber"

# Enforce naming rules
if ($newName.Length -gt 63 -or $newName -match '^[0-9]+$') {
    Log-Exit "Error: Invalid computer name '$newName'. Ensure it follows naming rules." 1
}
Write-Host ""
# Check if renaming is necessary
$currentName = (Get-ComputerInfo).CsName
if ($newName -ieq $currentName) {
    Log-Exit "No need to rename computer, name is already set to $newName" 0
}

# Handle Test Mode
if ($TestMode) {
    Write-Host "Test Mode: The computer would be renamed to '$newName', but no changes will be made."
    Log-Exit "Test mode complete." 0
}

# Attempt to rename the computer
try {
    Write-Host "Renaming computer to $newName"
    Rename-Computer -NewName $newName -Force
    Write-Host "Rename successful."

    # Skip reboot in Test Mode
    if (-not $TestMode) {
        Write-Host "Initiating a restart in 10 minutes."
        & shutdown.exe /g /t 600 /f /c "Restarting the computer due to a computer name change. Save your work."
    } else {
        Write-Host "Test mode active, skipping reboot."
    }

    Log-Exit "Restart initiated." 0
} catch {
    Log-Exit "Error: Failed to rename the computer. $_" 1
}
Write-Host ""
