# This script will automatically rename an AD/AAD-bound Windows computer to the machine's serial number based on the following command:
# "(Get-WmiObject -Class Win32_Bios | Select-Object -Last 1).SerialNumber" <-- this will print ONLY the serial number.

# Script starts
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



# Function to retrieve the serial number, with special handling for virtual machines
function Get-SerialNumber {
    try {
        # Retrieve system enclosure information
        $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure

        # Check if we are running on a virtual machine
        $isVirtualMachine = ($systemEnclosure.ChassisTypes -contains 3 -or
                             $systemEnclosure.ChassisTypes -contains 4)

        if ($isVirtualMachine) {
            Write-Host "Virtual machine detected."

            # Handle virtual machines
            $serialNumber = (Get-CimInstance -ClassName Win32_BIOS | Select-Object -ExpandProperty SerialNumber)
            if ($serialNumber -eq $null -or $serialNumber -match '^[ ]*$') {
                Write-Host "Unable to retrieve serial number for the virtual machine. Using fallback."
                $serialNumber = "VM-NoSerial"
            }
        } else {
            # Handle physical machines
            $serialNumber = (Get-CimInstance -ClassName Win32_BIOS | Select-Object -ExpandProperty SerialNumber)
            if ($serialNumber -eq $null -or $serialNumber -match '^[ ]*$') {
                Write-Host "Unable to retrieve serial number for the physical machine."
                $serialNumber = "Physical-NoSerial"
            }
        }

        return $serialNumber
    } catch {
        Write-Host "Error: Failed to retrieve serial number: $($_.Exception.Message)"
        return "Unknown-NoSerial"
    }
}

# Resolve the logged-on user's temp directory, default to C:\Windows\Temp if needed/no user detected
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

# Get the logged-on user and their Temp directory
$LoggedOnUser = Get-LoggedOnUserTemp

# Ensure the logged-on user is found and proceed with the transcript
if ($LoggedOnUser) {
    $LogFilePath = "C:\Users\$LoggedOnUser\AppData\Local\Temp\RenameComputer.log"
    Start-Transcript -Path $LogFilePath -Append
} else {
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
        $isAD = $true
    } else {
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
try {
    $serialNumber = Get-SerialNumber

    if (-not $serialNumber) {
        Log-Exit "Error: No serial number found." 1
    }

    if ($serialNumber.Length -gt 13) {
        $serialNumber = $serialNumber.Substring(0, 13)
    }

    $newName = "$serialNumber"
    Write-Host "The new computer name will be: $newName"

    $currentName = (Get-ComputerInfo).CsName
    if ($newName -ieq $currentName) {
        Log-Exit "No need to rename computer, name is already set to $newName" 0
    }

    Write-Host "Renaming computer to $newName"
    Rename-Computer -NewName $newName -Force
    Write-Host "Initiating a restart in 10 minutes."
    & shutdown.exe /g /t 600 /f /c "Restarting the computer due to a computer name change. Save your work."
    Log-Exit "Restart initiated." 0
} catch {
    Log-Exit "Error: Failed to rename the computer." 1
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
            Write-

Host "Scheduled task already exists."
        }
    } catch {
        Log-Exit "Error: Failed to create or check the scheduled task." 1
    }
}