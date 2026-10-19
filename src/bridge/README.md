# C11 IOKit & NVMe SMART Bridge (`src/bridge/`)

This directory contains the low-level C11 hardware telemetry bridge that interfaces directly with macOS system frameworks (`IOKit.framework`, `DiskArbitration.framework`, `CoreFoundation.framework`, and `<sys/mount.h>`).

Because macOS's `IONVMeSMARTUserClient` COM-style plugin interface (`IOCFPlugInInterface`) uses C function pointer vtables and raw byte buffers, implementing this layer in C11 provides deterministic memory layout, zero bridging overhead, and direct access to 128-bit NVMe counters.

---

## Files

### 1. [`DiskHealthBridge.h`](DiskHealthBridge.h)
Declares the C ABI data structures and functions exposed to Swift via `-import-objc-header`:
- **`DiskHardwareMetrics`**: Complete hardware telemetry structure for a single target drive, including:
  - Identity & topology: `bsdName`, `vendor`, `product`, `serial`, `protocol`, `transportSpeed`, `linkStatus`, `usbSpeedCode`, `isInternal`, `isRemovable`.
  - Block device metrics: `mediaSizeBytes`, `blockSizeBytes`, `isWriteProtected`, `smartStatus`.
  - Block storage driver statistics (`IOBlockStorageDriver`): `bytesRead`, `bytesWritten`, `readOperations`, `writeOperations`, `readErrors`, `writeErrors`, `readLatencyNs`, `writeLatencyNs`.
  - NVMe SMART health log fields (`IONVMeSMARTUserClient`): `smartSupported`, `nvmeCriticalWarning`, `nvmeTemperatureCelsius`, `nvmeAvailableSpare`, `nvmeAvailableSpareThreshold`, `nvmePercentageUsed`, `nvmeDataUnitsRead`, `nvmeDataUnitsWritten`, `nvmeHostReadCommands`, `nvmeHostWriteCommands`, `nvmeControllerBusyTime`, `nvmePowerCycles`, `nvmePowerOnHours`, `nvmeUnsafeShutdowns`, `nvmeMediaErrors`, `nvmeErrorLogEntries`.
- **`MountedDiskInfo`** & **`MountedDiskList`**: Fixed-capacity array (`MAX_DISKS = 64`) of all mounted volumes returned by `DiskListMountedDisks()`.
- **`DiskReadHardwareMetrics(const char *targetMountPath, const char *targetDeviceQuery)`**: Primary entry point for querying hardware metrics for a volume or device.
- **`DiskListMountedDisks(void)`**: Enumerates all mounted non-virtual volumes on the system.

### 2. [`DiskHealthBridge.c`](DiskHealthBridge.c)
Implements the hardware discovery and telemetry pipeline:
1. **Mount Point Resolution (`statfs` & `getmntinfo`)**:
   - Resolves a volume path (e.g., `/Volumes/MySSD` or `/`) or device query (`disk4`, product name, or serial number) to its BSD disk identifier (`diskXsY` or `diskX`).
2. **APFS Physical Store Traversal (`find_physical_disk_service`)**:
   - Synthesized APFS volumes (e.g., `/dev/disk3s1s1` or `/dev/disk6s2`) sit inside an `AppleAPFSContainer` virtual object in the IOKit tree and do not directly attach to hardware controllers.
   - `find_physical_disk_service` walks up the `kIOServicePlane` parent chain from the BSD partition node until it locates the underlying physical `IOMedia` whole disk, `IOBlockStorageDevice`, `IOUSBHostDevice`, or `IONVMeController`.
3. **128-Bit NVMe SMART Decoding (`read_u128_le_to_u64_saturated`)**:
   - Reads the 512-byte NVMe SMART/Health Information Log (`NVMeSMARTData`).
   - Properly inspects all 16 bytes of 128-bit little-endian fields (`Data Units Read`, `Data Units Written`, `Host Read Commands`, `Host Write Commands`, `Power Cycles`, `Power On Hours`, `Unsafe Shutdowns`, `Media Errors`), saturating to `UINT64_MAX` if the upper 64 bits are non-zero.
   - Converts composite Kelvin temperature to Celsius (`kelvin - 273`) with sanity bounds checking (`-20°C` to `150°C`).
4. **USB & Bus Speed Negotiation**:
   - Inspects `Device Speed` and `USBSpeed` properties across `IOUSBHostDevice` / `AppleUSBXHCI` ancestors to distinguish USB 2.0 High-Speed (`480 Mbps`), USB 3.0 SuperSpeed (`5 Gbps`), USB 3.2 Gen 2 SuperSpeedPlus (`10 Gbps`), and USB 3.2 Gen 2x2 (`20 Gbps`), or PCIe/Apple Fabric for internal drives.
