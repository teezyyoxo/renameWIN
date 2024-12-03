# This script will automatically rename an AD/AAD-bound Windows computer to the machine's serial number based on the following command:
# MG ON 11/27/24 --> OPTIMIZE PRETTIFICATION AND STUFF, ADD CHANGELOG TO SCRIPT (commented out)

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $False)] [string] $Prefix = "",
    [switch] $TestMode,  # -T for Test Mode
    [Alias("TestFlag")] [switch] $t # Renamed alias for Test Mode
)
# Clean your windshield and headlight lenses every now and then.
cls

# Combine TestMode flags (-t and -T)
$TestMode = $TestMode -or $t
Write-Host ""
# Heads up - test mode!
if ($TestMode) {
    Write-Warning "***SCRIPT IS BEING EXECUTED IN TEST MODE. NO CHANGES WILL BE APPLIED.***"
 } else {} # Carry on, my wayward son...
Write-Host ""

# Function to log and exit
function Log-Exit {
    param([string]$message, [int]$exitCode = 0)
    Write-Host $message

    # Stop transcript only if it's started
    if ($PSCmdlet.MyInvocation.BoundParameters["Transcript"] -and $Transcript) {
        Stop-Transcript
    }

    Exit $exitCode
}

# Opening credits. Star Wars???
Write-Host "winRename v1.7 by MG"
Write-Host ""
Write-Host ""

Write-Host "Based on version 1.3 of Michael Niehaus' RenameComputer.ps1 script."
Write-Host "EXCELLENT write-up on it on his blog."
Write-Host "https://oofhours.com/2020/05/19/renaming-autopilot-deployed-hybrid-azure-ad-join-devices/"
Write-Host "---------------------------------------------------"
Write-Host ""

# Function to retrieve and validate the serial number
function Get-SerialNumber {
    try {
        # Detect if the system is a virtual machine
        $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure
        $isVirtualMachine = ($systemEnclosure.ChassisTypes -contains 3 -or
                             $systemEnclosure.ChassisTypes -contains 4)
        if ($isVirtualMachine) {
            Write-Host "Virtual environment/architecture detected. Serial number retrieval may produce unexpected results."
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

# Function to retrieve the user's temp directory and print logging.
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
            if ($TestMode) {
                Write-Warning "Running script as SYSTEM user."
                Write-Warning "Using C:\Windows\Temp for logs."
            }
            # Always log to the transcript
            Write-Warning "Running script as SYSTEM user."
            Write-Warning "Using C:\Windows\Temp for logs."
            return "C:\Windows\Temp"
        }
    } catch {
        if ($TestMode) {
            Write-Warning "Error resolving user's temp directory: $($_.Exception.Message)"
        }
        Write-Warning "Error resolving user's temp directory: $($_.Exception.Message)"
        return "C:\Windows\Temp"
    }
}

# Check if AD or Hybrid/AAD joined
$isAD = $false
$isAAD = $false
$tenantID = $null
try {
    $details = Get-ComputerInfo
    if ($details.CsPartOfDomain) {
        Write-Host "Device is joined to Active Directory domain: $($details.CsDomain)"
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

# Check if renaming is necessary
$currentName = (Get-ComputerInfo).CsName

# Print the current and corrected computer names
Write-Host "Current Computer Name:"
Write-Host "$currentName"
Write-Host ""
Write-Host "Corrected Computer Name:"
Write-Host "$newName"
Write-Host ""

if ($newName -ieq $currentName) {
    Log-Exit "No need to rename computer, name is already set to $newName" 0
}

# Handle Test Mode
if ($TestMode) {
    Write-Host "***SCRIPT WAS RUN IN TEST MODE.***"
    Write-Host "No changes have been applied."
    Log-Exit "Exiting."
}

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

# Attempt to rename the computer
try {
    Write-Host "Renaming computer to $newName."
    Rename-Computer -NewName $newName -Force
    Write-Host "Rename successful."

    # Skip reboot in Test Mode
    if (-not $TestMode) {
        Write-Host "Initiating a restart in 30 seconds."
        & shutdown.exe /g /t 30 /f /c "Restarting the computer due to a computer name change. Save your work."
    } else {
        Write-Host "Test mode active, skipping reboot."
    }

    Log-Exit "Restart initiated." 0
} catch {
    Log-Exit "Error: Failed to rename the computer. $_" 1
}

Write-Host ""