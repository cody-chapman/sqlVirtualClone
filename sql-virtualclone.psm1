<# 
    .SYNOPSIS 
    Powershell Module that setups and helps orchestrate clones of SQL Server databases without Hyper-V dependencies.
    .VERSIONINFO 2.0.0
    .DESCRIPTION
    Utilizes native Windows Storage Engine and diskpart alongside SQL Server to orchestrate high-speed,
    low-footprint database virtualization using VHDX differencing chains.
    
    Must be run within an Elevated (Administrator) PowerShell Session.
#>

# ==========================================
# INTERNAL UTILITIES & DATABASE HELPERS
# ==========================================

function Invoke-SqlVcDiskPart {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ScriptContent)
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tempFile -Value $ScriptContent -Encoding Ascii
    $output = diskpart /s $tempFile
    Remove-Item $tempFile -Force
    return $output
}

function Backup-SqlVcDatabase {
    param([string]$DatabaseName, [string]$BackupFile, [string]$BackupName)
    Write-Verbose "Backing up database [$DatabaseName] to [$BackupFile]..."
    $query = "BACKUP DATABASE [$DatabaseName] TO DISK = N'$BackupFile' WITH FORMAT, INIT, NAME = N'$BackupName', SKIP, NOREWIND, NOUNLOAD, STATS = 10;"
    Invoke-Sqlcmd -Query $query -ServerInstance "." -QueryTimeout 3600
}

function Restore-SqlVcDatabase {
    param([string]$BackupFile, [string]$NewLocation, [string]$NewDatabaseName)
    Write-Verbose "Analyzing backup file layout for [$NewDatabaseName]..."
    
    # Dynamically extract logical and physical file components from backup
    $files = Invoke-Sqlcmd -Query "RESTORE FILELISTONLY FROM DISK = N'$BackupFile';" -ServerInstance "."
    
    $moveClause = @()
    foreach ($file in $files) {
        $logicalName = $file.LogicalName
        $physicalName = $file.PhysicalName
        $ext = [System.IO.Path]::GetExtension($physicalName)
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($physicalName)
        
        $newPhysicalPath = Join-Path $NewLocation "$NewDatabaseName`_$fileName$ext"
        $moveClause += "MOVE '$logicalName' TO '$newPhysicalPath'"
    }
    $moveQueryParam = $moveClause -join ", "
    
    Write-Verbose "Restoring Base Image Database [$NewDatabaseName] onto virtual disk..."
    $query = "RESTORE DATABASE [$NewDatabaseName] FROM DISK = N'$BackupFile' WITH $moveQueryParam, RECOVERY, REPLACE, STATS = 10;"
    Invoke-Sqlcmd -Query $query -ServerInstance "." -QueryTimeout 3600
}

function Disconnect-SqlVcDatabase {
    param([string]$DatabaseName)
    Write-Verbose "Detaching database [$DatabaseName] from instance..."
    $query = @"
ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
EXEC sp_detach_db @dbname = N'$DatabaseName';
"@
    Invoke-Sqlcmd -Query $query -ServerInstance "." -ErrorAction SilentlyContinue
}

function Connect-SqlVcDatabase {
    param([string]$DatabaseName, [string[]]$DatabaseFiles)
    Write-Verbose "Attaching clone database [$DatabaseName]..."
    
    $fileFilesClause = @()
    foreach ($file in $DatabaseFiles) {
        $fileFilesClause += "(FILENAME = N'$file')"
    }
    $filesQueryParam = $fileFilesClause -join ", "
    
    $query = "CREATE DATABASE [$DatabaseName] ON $filesQueryParam FOR ATTACH;"
    Invoke-Sqlcmd -Query $query -ServerInstance "."
}

function Remove-SqlVcDatabase {
    param([string]$DatabaseName)
    Write-Verbose "Dropping clone database [$DatabaseName]..."
    $query = @"
ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [$DatabaseName];
"@
    Invoke-Sqlcmd -Query $query -ServerInstance "." -ErrorAction SilentlyContinue
}

# ==========================================
# PUBLIC CORE FUNCTIONS
# ==========================================

function Set-SqlVcDatabaseState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DatabaseName,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Online", "Offline")]      
        [string]$DatabaseAction
    )    
    switch ($DatabaseAction) {
        "Online"  { $SQLAction = "ONLINE" }
        "Offline" { $SQLAction = "OFFLINE WITH ROLLBACK IMMEDIATE" }
    }
    
    $SQLCMD = "USE master; ALTER DATABASE [$DatabaseName] SET $SQLAction;"  
    Invoke-Sqlcmd -Query $SQLCMD -QueryTimeout 3600 -ServerInstance "."
    
    $retval = Invoke-Sqlcmd -Query "SELECT state_desc as IsOnline FROM sys.databases WHERE name = '$DatabaseName';" -ServerInstance "."
    if ($retval.IsOnline -eq "ONLINE") {
        Write-Verbose "[$DatabaseName] state verified as ONLINE"
    } else {
        Write-Verbose "[$DatabaseName] state verified as OFFLINE"
    }
}

function New-SqlVcImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DatabaseName,
        [Parameter(Mandatory=$true)]
        [string]$BaseDirectory,
        [Parameter(Mandatory=$true)]
        [string]$NewDatabaseName
    )
    
    $VHDFile       = Join-Path $BaseDirectory "$NewDatabaseName\VHD\$NewDatabaseName.vhdx"
    $VHDMountPath  = Join-Path $BaseDirectory "$NewDatabaseName\Mount\"
    $BackupDir     = Join-Path $BaseDirectory "$NewDatabaseName\Backup\"
    $BackupFile    = Join-Path $BaseDirectory "$NewDatabaseName\Backup\$NewDatabaseName.bak"

    # Infrastructure Directory Mapping
    $null = New-Item -ItemType Directory -Path $VHDMountPath -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $BackupDir -ErrorAction SilentlyContinue

    # Disk Generation via native diskpart (2040 GB = 2088960 MB)
    Write-Verbose "Generating Expandable Parent VHDX File..."
    $diskpartScript = "create vdisk file=""$VHDFile"" maximum=2088960 type=expandable"
    $null = Invoke-SqlVcDiskPart -ScriptContent $diskpartScript

    # Attachment via native Windows Storage Engine
    Write-Verbose "Mounting Parent VHDX..."
    $null = Mount-DiskImage -ImagePath $VHDFile -StorageType VHDX
    Start-Sleep -Seconds 2 # Allow Win32 storage sub-system registration

    # Storage Architecture Preparation
    $disk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
    $disk | Initialize-Disk -PartitionStyle MBR -ErrorAction SilentlyContinue | Out-Null
    $partition = $disk | New-Partition -UseMaximumSize
    $partition | Format-Volume -FileSystem NTFS -Confirm:$false | Out-Null
    $partition | Add-PartitionAccessPath -AccessPath $VHDMountPath | Out-Null

    # Virtual Deployment Execution Loop
    Backup-SqlVcDatabase -BackupFile $BackupFile -DatabaseName $DatabaseName -BackupName $NewDatabaseName
    Restore-SqlVcDatabase -BackupFile $BackupFile -NewLocation $VHDMountPath -NewDatabaseName $NewDatabaseName

    # SQL Decoupling and Volume Teardown
    Disconnect-SqlVcDatabase -DatabaseName $NewDatabaseName
    
    Write-Verbose "Dismounting Parent VHDX..."
    $null = Dismount-DiskImage -ImagePath $VHDFile

    # Structural Cleanup
    if (Test-Path $BackupDir) { Remove-Item $BackupDir -Force -Recurse -ErrorAction SilentlyContinue }
    if (Test-Path $VHDMountPath) { Remove-Item $VHDMountPath -Force -Recurse -ErrorAction SilentlyContinue }
}

function Remove-SqlVcImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$BaseDirectory,
        [Parameter(Mandatory=$true)]
        [string]$NewDatabaseName
    )
    $VHDFile  = Join-Path $BaseDirectory "$NewDatabaseName\VHD\$NewDatabaseName.vhdx"
    $CloneDir = Join-Path $BaseDirectory "$NewDatabaseName\"

    Disconnect-SqlVcDatabase -DatabaseName $NewDatabaseName
    $null = Dismount-DiskImage -ImagePath $VHDFile -ErrorAction SilentlyContinue
    
    if (Test-Path $CloneDir) { Remove-Item $CloneDir -Force -Recurse -ErrorAction SilentlyContinue }
}

function New-SqlVcClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CloneDatabaseName,
        [Parameter(Mandatory=$true)]
        [string]$BaseDirectory,
        [Parameter(Mandatory=$true)]
        [string]$NewDatabaseName
    )
    $VHDFile            = Join-Path $BaseDirectory "$NewDatabaseName\VHD\$NewDatabaseName.vhdx"
    $VHDCloneMountPath  = Join-Path $BaseDirectory "$NewDatabaseName\$CloneDatabaseName\Mount\"
    $ChildVHDFile       = Join-Path $BaseDirectory "$NewDatabaseName\VHD\$CloneDatabaseName.vhdx"

    $null = New-Item -ItemType Directory -Path $VHDCloneMountPath -ErrorAction SilentlyContinue

    # Generate Differencing Disk natively via diskpart (Points back to immutable parent VHDX)
    Write-Verbose "Creating Differencing VHDX..."
    $diskpartScript = "create vdisk file=""$ChildVHDFile"" parent=""$VHDFile"""
    $null = Invoke-SqlVcDiskPart -ScriptContent $diskpartScript

    # Mount Virtual Drive
    Write-Verbose "Mounting Child VHDX..."
    $null = Mount-DiskImage -ImagePath $ChildVHDFile -StorageType VHDX
    Start-Sleep -Seconds 2

    $disk = Get-DiskImage -ImagePath $ChildVHDFile | Get-Disk
    $disk | Set-Disk -IsOffline $false -ErrorAction SilentlyContinue | Out-Null
    
    # Strip automatically assigned drive letters to preserve mount-path scheme
    $partition = Get-Partition -DiskNumber $disk.DiskNumber
    if ($partition.DriveLetter) {
        Remove-PartitionAccessPath -AccessPath "$($partition.DriveLetter):\" -DiskNumber $disk.DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue | Out-Null
    }
    $partition | Add-PartitionAccessPath -AccessPath $VHDCloneMountPath | Out-Null

    # Dynamically locate DB payload components within the Virtual Drive Mount
    $DBFiles = Get-ChildItem -Path $VHDCloneMountPath -File | Select-Object -ExpandProperty FullName

    Connect-SqlVcDatabase -DatabaseFiles $DBFiles -DatabaseName $CloneDatabaseName
}

function Remove-SqlVcClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CloneDatabaseName,
        [Parameter(Mandatory=$true)]
        [string]$BaseDirectory,
        [Parameter(Mandatory=$true)]
        [string]$NewDatabaseName
    )
    $VHDFile  = Join-Path $BaseDirectory "$NewDatabaseName\VHD\$CloneDatabaseName.vhdx"
    $CloneDir = Join-Path $BaseDirectory "$NewDatabaseName\$CloneDatabaseName"

    Remove-SqlVcDatabase -DatabaseName $CloneDatabaseName
    $null = Dismount-DiskImage -ImagePath $VHDFile -ErrorAction SilentlyContinue

    if (Test-Path $VHDFile) { Remove-Item -Path $VHDFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $CloneDir) { Remove-Item -Path $CloneDir -Force -Recurse -ErrorAction SilentlyContinue }
}

function Initialize-SqlVcEnvironment {
    [CmdletBinding()]
    param()
    # Forces global Windows OS subsystem to auto-online newly bound storage footprints
    Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
    Write-Verbose "Storage System Policy set to OnlineAll."
}

Export-ModuleMember -Function 'Set-SqlVcDatabaseState', 'New-SqlVcImage', 'Remove-SqlVcImage', 'New-SqlVcClone', 'Remove-SqlVcClone', 'Initialize-SqlVcEnvironment'
