# sqlVirtualClone

A powerful PowerShell module for orchestrating high-speed, low-footprint SQL Server database clones using Windows native storage virtualization. Clone production databases without Hyper-V dependencies—leveraging VHDX differencing chains for efficient disk space utilization.

**Version:** 2.0.0  
**License:** BSD 2-Clause "Simplified" License

---

## Features

✨ **High-Performance Database Cloning**
- Create full database clones in seconds using VHDX differencing disks
- Minimal disk space overhead—child clones only store changes from the parent image
- No Hyper-V dependency—uses native Windows Storage Engine

⚙️ **Automated Orchestration**
- Backup and restore databases to/from virtual disks with a single command
- Dynamically extract and attach database files without manual configuration
- Automatic storage policy management for seamless virtual disk integration

🛡️ **Enterprise-Grade Operations**
- Safe database detach/attach operations with rollback support
- Online/Offline database state management
- Built-in error handling and cleanup routines

📦 **Space-Efficient Architecture**
- Parent base image stored once on VHDX
- Multiple child clones created as differencing disks pointing to the immutable parent
- 2TB expandable disk capacity per image (configurable)

---

## Requirements

- **PowerShell** 3.0 or higher
- **Windows 10** or **Windows Server 2016+**
- **SQL Server** 2012 or higher (with SQL Server PowerShell module)
- **Administrator privileges** (required for disk operations)
- **Available disk space** for base image and clone disks

---

## Installation

1. Clone or download the module:
```powershell
git clone https://github.com/cody-chapman/sqlVirtualClone.git
```

2. Copy the module to your PowerShell modules directory:
```powershell
Copy-Item -Path ".\sql-virtualclone.psm1" -Destination "$PSHOME\Modules\sqlVirtualClone\"
```

Or add the module path to your PowerShell profile:
```powershell
$env:PSModulePath += ";C:\Path\To\sqlVirtualClone"
```

3. Import the module:
```powershell
Import-Module sqlVirtualClone
```

4. Initialize the storage environment:
```powershell
Initialize-SqlVcEnvironment
```

---

## Quick Start

### Create a Base Image

Create an immutable base image from an existing database backup:

```powershell
New-SqlVcImage `
    -DatabaseName "Production" `
    -BaseDirectory "D:\SqlClones" `
    -NewDatabaseName "ProdBaseImage"
```

**What this does:**
- Backs up the source database to a VHDX virtual disk
- Creates directory structure: `D:\SqlClones\ProdBaseImage\VHD\`, `Backup\`, `Mount\`
- Generates a 2TB expandable VHDX parent disk
- Mounts, initializes, and formats the virtual disk
- Restores the backup onto the virtual disk
- Detaches the database and dismounts the disk
- Cleans up temporary backup files

### Create Database Clones

Create instant clones from the base image using differencing disks:

```powershell
New-SqlVcClone `
    -CloneDatabaseName "QA_Clone_001" `
    -BaseDirectory "D:\SqlClones" `
    -NewDatabaseName "ProdBaseImage"
```

**What this does:**
- Creates a child VHDX differencing disk linked to the parent
- Mounts the child disk to `D:\SqlClones\ProdBaseImage\QA_Clone_001\Mount\`
- Dynamically locates database files on the mounted disk
- Attaches the database to SQL Server as `QA_Clone_001`

Create multiple clones in parallel:

```powershell
1..5 | ForEach-Object {
    New-SqlVcClone `
        -CloneDatabaseName "Dev_Clone_$_" `
        -BaseDirectory "D:\SqlClones" `
        -NewDatabaseName "ProdBaseImage"
}
```

### Manage Database State

Take clones online or offline for testing, backup, or maintenance:

```powershell
# Take a clone offline
Set-SqlVcDatabaseState -DatabaseName "QA_Clone_001" -DatabaseAction Offline

# Bring it back online
Set-SqlVcDatabaseState -DatabaseName "QA_Clone_001" -DatabaseAction Online
```

### Remove Clones

Clean up individual clones when no longer needed:

```powershell
Remove-SqlVcClone `
    -CloneDatabaseName "QA_Clone_001" `
    -BaseDirectory "D:\SqlClones" `
    -NewDatabaseName "ProdBaseImage"
```

**What this does:**
- Detaches the clone database from SQL Server
- Dismounts the child VHDX disk
- Removes the clone VHDX file and directory structure
- Frees up disk space

### Remove Base Image

Clean up the base image and all associated storage:

```powershell
Remove-SqlVcImage `
    -BaseDirectory "D:\SqlClones" `
    -NewDatabaseName "ProdBaseImage"
```

---

## Function Reference

### Public Functions

#### `Initialize-SqlVcEnvironment`
Configures Windows storage policy to automatically bring newly mounted disks online.

```powershell
Initialize-SqlVcEnvironment
```

**Parameters:** None  
**Returns:** None  
**Notes:** Run once before creating base images

---

#### `New-SqlVcImage`
Creates a base image from an existing database, stored as an immutable parent VHDX.

```powershell
New-SqlVcImage -DatabaseName <string> -BaseDirectory <string> -NewDatabaseName <string>
```

**Parameters:**
- `-DatabaseName` (Required): Source database name on local SQL Server instance
- `-BaseDirectory` (Required): Root directory for storage (e.g., `D:\SqlClones`)
- `-NewDatabaseName` (Required): Name for the base image

**Returns:** None  
**Creates:** Directory structure with VHDX parent disk, backup, and mount paths

---

#### `Remove-SqlVcImage`
Removes a base image and all associated storage.

```powershell
Remove-SqlVcImage -BaseDirectory <string> -NewDatabaseName <string>
```

**Parameters:**
- `-BaseDirectory` (Required): Root directory for storage
- `-NewDatabaseName` (Required): Name of the base image to remove

**Returns:** None  
**Removes:** VHDX disk, database attachment, and directories

---

#### `New-SqlVcClone`
Creates an instant clone as a differencing disk child linked to the parent.

```powershell
New-SqlVcClone -CloneDatabaseName <string> -BaseDirectory <string> -NewDatabaseName <string>
```

**Parameters:**
- `-CloneDatabaseName` (Required): Name for the new clone database
- `-BaseDirectory` (Required): Root directory for storage
- `-NewDatabaseName` (Required): Name of the parent base image

**Returns:** None  
**Creates:** Child VHDX differencing disk and SQL database

---

#### `Remove-SqlVcClone`
Removes a clone database and its differencing disk.

```powershell
Remove-SqlVcClone -CloneDatabaseName <string> -BaseDirectory <string> -NewDatabaseName <string>
```

**Parameters:**
- `-CloneDatabaseName` (Required): Name of the clone to remove
- `-BaseDirectory` (Required): Root directory for storage
- `-NewDatabaseName` (Required): Name of the parent base image

**Returns:** None  
**Removes:** Child VHDX disk, database, and directories

---

#### `Set-SqlVcDatabaseState`
Brings a database online or takes it offline.

```powershell
Set-SqlVcDatabaseState -DatabaseName <string> -DatabaseAction <Online|Offline>
```

**Parameters:**
- `-DatabaseName` (Required): Name of the database
- `-DatabaseAction` (Required): `Online` or `Offline`

**Returns:** State verification string  
**Notes:** Includes rollback for immediate termination of connections

---

### Internal Functions

The following helper functions are available but intended for internal use:

- `Invoke-SqlVcDiskPart` – Executes diskpart scripts
- `Backup-SqlVcDatabase` – Backs up a database to disk
- `Restore-SqlVcDatabase` – Restores a database from backup with dynamic file mapping
- `Connect-SqlVcDatabase` – Attaches a database by file list
- `Disconnect-SqlVcDatabase` – Detaches a database
- `Remove-SqlVcDatabase` – Drops a database

---

## Use Cases

### Development & Testing
Spin up fresh database clones for each developer or test iteration:
```powershell
# Create 10 independent dev databases from a single production backup
1..10 | ForEach-Object {
    New-SqlVcClone -CloneDatabaseName "DevDB_$_" -BaseDirectory "D:\SqlClones" -NewDatabaseName "ProdImage"
}
```

### Quality Assurance
Provision QA environments on-demand with production-like data:
```powershell
New-SqlVcClone -CloneDatabaseName "QA_Release_1.5" -BaseDirectory "D:\SqlClones" -NewDatabaseName "ProdImage"
```

### Training & Demos
Create isolated, independent databases for training without data sprawl:
```powershell
New-SqlVcClone -CloneDatabaseName "Training_Group_A" -BaseDirectory "D:\SqlClones" -NewDatabaseName "ProdImage"
```

### Compliance Testing
Quickly provision test environments for security or compliance validation:
```powershell
New-SqlVcClone -CloneDatabaseName "Compliance_Test_Q1" -BaseDirectory "D:\SqlClones" -NewDatabaseName "ProdImage"
```

---

## Disk Space Benefits

**Traditional Approach:**
- Full backup: 500 GB
- Clone 1: +500 GB
- Clone 2: +500 GB
- Clone 3: +500 GB
- **Total: 2 TB**

**sqlVirtualClone Approach:**
- Parent VHDX: 500 GB
- Clone 1: ~10 GB (changes only)
- Clone 2: ~10 GB (changes only)
- Clone 3: ~10 GB (changes only)
- **Total: 530 GB** (73% space savings)

---

## Architecture

```
BaseDirectory/
└── ProdBaseImage/
    ├── VHD/
    │   ├── ProdBaseImage.vhdx (parent, immutable)
    │   ├── Clone_001.vhdx (differencing child)
    │   ├── Clone_002.vhdx (differencing child)
    │   └── Clone_003.vhdx (differencing child)
    ├── Clone_001/
    │   └── Mount/ (mounted VHDX filesystem)
    ├── Clone_002/
    │   └── Mount/
    ├── Clone_003/
    │   └── Mount/
    └── Backup/
        └── ProdBaseImage.bak (temporary, removed after image creation)
```

---

## Troubleshooting

### Module Not Loading
Ensure you're running PowerShell as Administrator and that the module path is correct:
```powershell
Get-Module -ListAvailable -Name sqlVirtualClone
```

### Disk Space Issues
Check available space and VHDX disk usage:
```powershell
Get-Item "D:\SqlClones\ProdBaseImage\VHD\*.vhdx" | ForEach-Object {
    Get-VirtualDisk -Path $_.FullName | Select-Object Name, Size, FileSize
}
```

### Database Attachment Failures
Verify database files are accessible on the mounted VHDX:
```powershell
Get-ChildItem -Path "D:\SqlClones\ProdBaseImage\Clone_001\Mount\"
```

### Disk Not Mounting
Manually mount if automatic mounting fails:
```powershell
Mount-DiskImage -ImagePath "D:\SqlClones\ProdBaseImage\VHD\Clone_001.vhdx" -StorageType VHDX
```

---

## Performance Notes

- **Clone Creation:** Typically 5-15 seconds per clone (compared to minutes for traditional backup/restore)
- **Disk I/O:** Differencing disks have minimal overhead; performance depends on parent VHDX and system I/O
- **Concurrent Clones:** Can create/manage dozens of clones with minimal resource impact
- **Backup Size:** Parent image size matches source database size; subsequent clones add negligible space

---

## Best Practices

1. **Dedicate Storage:** Use a fast, dedicated volume (SSD or high-speed HDD) for base images
2. **Regular Base Updates:** Recreate base images periodically to keep backups current
3. **Monitor Space:** Track differencing disk growth; recreate large clones to reset changes
4. **Cleanup Policy:** Regularly remove unused clones to free disk space
5. **Backup Strategy:** Don't rely solely on clones; maintain traditional backups for long-term retention
6. **Documentation:** Label clones clearly (clone name, creation date, purpose)

---

## Limitations

- Windows OS only (requires Windows storage virtualization support)
- SQL Server on Windows only (no SQL Server on Linux support)
- Local SQL Server instance only (no remote instance support via ".")
- VHDX parent immutability recommended (modifying parent breaks child clones)
- Maximum VHDX size: 64 TB (configured as 2 TB, editable in code)

---

## Contributing

Contributions are welcome! To contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit changes with clear messages
4. Push to your fork and submit a pull request

---

## License

This project is licensed under the **BSD 2-Clause "Simplified" License**. See the LICENSE file for details.

---

## Support

For issues, questions, or suggestions:
- Open an [issue](https://github.com/cody-chapman/sqlVirtualClone/issues) on GitHub
- Check existing issues for solutions
- Provide detailed reproduction steps and environment information

---

## Changelog

### Version 2.0.0
- Complete rewrite with enhanced error handling
- Support for VHDX differencing chains
- Automated storage policy management
- Dynamic database file discovery and attachment
- Improved documentation and inline comments

### Version 1.x
- Initial implementation with VHD support

---

## Author

**Cody Chapman**  
GitHub: [@cody-chapman](https://github.com/cody-chapman)

---

**Made with ❤️ for SQL Server administrators and developers**
