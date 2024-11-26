# This script will automatically rename an AD/AAD-bound Windows computer to the machine's serial number based on the following command:
# "(Get-WmiObject -Class Win32_Bios | Select-Object -Last 1).SerialNumber" <-- this will print ONLY the serial number.

#script starts
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $False)] [string] $Prefix = "",
    [switch] $TestMode  # -t or -T for test mode
)
# Function to log and exit
function Log-Exit {
    param([string]$message, [int]$exitCode = 0)
    Write-Host $message
    Stop-Transcript
    Exit $exitCode
}

# Print initial information about the script version and credits
Write-Host ""
Write-Host "RenameComputer v1.4"
Write-Host "Based on version 1.3 (latest) of Michael Niehaus' RenameComputer.ps1 script."
Write-Host "EXCELLENT write-up on it on his blog, here: https://oofhours.com/2020/05/19/renaming-autopilot-deployed-hybrid-azure-ad-join-devices/"
Write-Host ""
Write-Host "Script is running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host ""

# Resolve the logged-on user's temp directory, default to C:\Windows\Temp if needed/no user detected
function Get-LoggedOnUserTemp {
    try {
        # Try to get the logged-on user from WMI
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
            # No logged-on user found, so fall back to C:\Windows\Temp
            Write-Warning "No logged-on user found, using SYSTEM temp directory."
            return "C:\Windows\Temp"
        }
    } catch {
        Write-Warning "Error resolving logged-on user's temp directory: $($_.Exception.Message)"
        return "C:\Windows\Temp"
    }
}



# Get the logged-on user and their Temp directory
$LoggedOnUser = Get-LoggedOnUserTemp

# Ensure the logged-on user is found and proceed with the transcript
if ($LoggedOnUser) {
    # Start logging the session to a file
    $LogFilePath = "C:\Users\$LoggedOnUser\AppData\Local\Temp\RenameComputer.log"
    Start-Transcript -Path $LogFilePath -Append
} else {
    # If no logged-on user is found, display a message and don't start the transcript
    Write-Host "Unable to resolve logged-on user's temp directory. Transcript not started."
}


# Create a tag file just so Intune knows this was installed
try {
    if (-not (Test-Path "$($env:ProgramData)\Microsoft\RenameComputer")) {
        Mkdir "$($env:ProgramData)\Microsoft\RenameComputer"
    }
    Set-Content -Path "$($env:ProgramData)\Microsoft\RenameComputer\RenameComputer.ps1.tag" -Value "Installed"
    if ($TestMode) { Write-Verbose "Created tag file at $($env:ProgramData)\Microsoft\RenameComputer\RenameComputer.ps1.tag" }
} catch {
    Log-Exit "Error: Failed to create or write to the tag file." 1
}

# Initialization
$dest = "$($env:ProgramData)\Microsoft\RenameComputer"
try {
    if (-not (Test-Path $dest)) {
        mkdir $dest
    }
    Start-Transcript "$dest\RenameComputer.log" -Append
    if ($TestMode) { Write-Verbose "Initialized log at $dest\RenameComputer.log" }
} catch {
    Log-Exit "Error: Failed to initialize the log directory." 1
}

# Bail out if the prefix doesn't match (if specified)
if ($Prefix -ne "") {
    $details = Get-ComputerInfo
    if ($details.CsName -notlike "$Prefix*") {
        Log-Exit "Device name doesn't match specified prefix. Prefix=$Prefix ComputerName=$($details.CsName)" 0
    }
}

# Detect if the computer is AD or AAD joined
$isAD = $false
$isAAD = $false
$tenantID = $null
try {
    $details = Get-ComputerInfo
    if ($details.CsPartOfDomain) {
        Write-Host "Device is joined to AD domain: $($details.CsDomain)"
        if ($TestMode) { Write-Verbose "Device is part of Active Directory." }
        $isAD = $true
    } else {
        if ($TestMode) { Write-Verbose "Device is not in AD, checking for AAD membership." }
        if (Test-Path "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo") {
            $subKey = Get-Item "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo"
            $guids = $subKey.GetSubKeyNames()
            foreach ($guid in $guids) {
                $guidSubKey = $subKey.OpenSubKey($guid)
                $tenantID = $guidSubKey.GetValue("TenantId")
            }
        }
        if ($tenantID) {
            Write-Host "Device is joined to AAD tenant: $tenantID"
            if ($TestMode) { Write-Verbose "Device is part of Azure Active Directory." }
            $isAAD = $true
        } else {
            Write-Host "Not part of a domain or AAD, in a workgroup."
        }
    }
} catch {
    Log-Exit "Error: Failed to detect AD or AAD domain membership." 1
}

# Check if connectivity to domain is good
if ($isAD) {
    try {
        $dcInfo = [ADSI]"LDAP://RootDSE"
        if ($null -eq $dcInfo.dnsHostName) {
            Log-Exit "No connectivity to the domain, unable to rename at this point." 1
        }
    } catch {
        Log-Exit "Error: Failed to check domain connectivity." 1
    }
}

# If we're good to go, rename the computer
if ($TestMode) {
    Write-Host "Test Mode: The computer would be renamed but no changes will be made."
    Write-Host "Would rename computer to: $newName"  # This will print the new name that will be used.
} else {
    try {
        # Remove existing scheduled task if it exists
        Disable-ScheduledTask -TaskName "RenameComputer" -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "RenameComputer" -Confirm:$false -ErrorAction SilentlyContinue

        # Get the serial number from Win32_Bios
        $serialNumber = (Get-WmiObject -Class Win32_Bios | Select-Object -Last 1).SerialNumber

        # Check if the serial number exists and is valid
        if (-not $serialNumber) {
            Log-Exit "Error: No serial number found." 1
        }

        # Ensure the serial number is within valid length (not too long)
        if ($serialNumber.Length -gt 13) {
            $serialNumber = $serialNumber.Substring(0, 13)
        }

        # Construct the new name based on the serial number
        $newName = "$serialNumber"  # Assuming the device is a desktop; adjust for laptop if needed
        Write-Host "The new computer name will be: $newName"

        # Check if the new name is the same as the current name
        $currentName = (Get-ComputerInfo).CsName
        if ($newName -ieq $currentName) {
            Log-Exit "No need to rename computer, name is already set to $newName" 0
        }

        Write-Host "Renaming computer to $newName"
        Rename-Computer -NewName $newName -Force
        if ($TestMode) { Write-Verbose "Successfully renamed computer to $newName" }

        # Restart if necessary
        Write-Host "Initiating a restart in 10 minutes."
        & shutdown.exe /g /t 600 /f /c "Restarting the computer due to a computer name change. Save your work."
        Log-Exit "Restart initiated." 0
    } catch {
        Log-Exit "Error: Failed to rename the computer." 1
    }
}

# Check and create the scheduled task if necessary
if (-not $TestMode) {
    try {
        $existingTask = Get-ScheduledTask -TaskName "RenameComputer" -ErrorAction SilentlyContinue
        if ($existingTask -eq $null) {
            if (-not (Test-Path "$dest\RenameComputer.ps1")) {
                Copy-Item $PSCommandPath "$dest\RenameComputer.ps1"
            }
            $action = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "-NoProfile -ExecutionPolicy bypass -WindowStyle Hidden -File $dest\RenameComputer.ps1"
            $timespan = New-Timespan -Minutes 5
            $triggers = @(
                New-ScheduledTaskTrigger -Daily -At 9am
                New-ScheduledTaskTrigger -AtLogOn -RandomDelay $timespan
                New-ScheduledTaskTrigger -AtStartup -RandomDelay $timespan
            )
            Register-ScheduledTask -User SYSTEM -Action $action -Trigger $triggers -TaskName "RenameComputer" -Description "RenameComputer" -Force
            Write-Host "Scheduled task created."
        } else {
            Write-Host "Scheduled task already exists."
        }
    } catch {
        Log-Exit "Error: Failed to create or register the scheduled task." 1
    }
}

Stop-Transcript
