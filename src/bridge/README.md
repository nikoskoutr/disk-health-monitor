# C11 IOKit & NVMe SMART Bridge (`src/bridge/`)

This directory contains the low-level C11 hardware telemetry bridge that interfaces directly with macOS system frameworks (`IOKit.framework`, `DiskArbitration.framework`, `CoreFoundation.framework`, and `<sys/mount.h>`).

Because macOS's `IONVMeSMARTUserClient` COM-style plugin interface (`IOCFPlugInInterface`) uses C function pointer vtables and raw byte buffers, implementing this layer in C11 provides deterministic memory layout, zero bridging overhead, and direct access to 128-bit NVMe counters.

---

## Files

### 1. [`DiskHealthBridge.h`](DiskHealthBridge.h)
Declares the C ABI data structures and functions exposed to Swift via `-import-objc-header`:
- **`DiskHardwareMetrics`**: Complete hardware telemetry structure for a single target drive, including:
  - Identity & topology: `bsdName`, `vendorName`, `productName`, `productRevision`, `serialNumber`, `usbSerialNumber`, `interconnectType`, `protocolType`, `isInternal`, `isRemovable`, `linkSpeedBps`, `usbLinkSpeedBps`.
  - NVMe SMART health log fields (`IONVMeSMARTUserClient`): `smartValid`, `criticalWarning`, `temperatureCelsius`, `temperatureKelvin`, `availableSpare`, `availableSpareThreshold`, `percentageUsed`, `dataUnitsRead`, `dataUnitsWritten`, `hostReadCommands`, `hostWriteCommands`, `controllerBusyTime`, `powerCycles`, `powerOnHours`, `unsafeShutdowns`, `mediaErrors`, `errorInfoLogEntries`.
  - Block storage driver statistics (`IOBlockStorageDriver`): `statsValid`, `bytesRead`, `bytesWritten`, `operationsRead`, `operationsWritten`, `errorsRead`, `errorsWritten`, `retriesRead`, `retriesWritten`, `totalTimeReadNs`, `totalTimeWriteNs`.
- **`DiskReadHardwareMetrics(const char *targetIdentifier, DiskHardwareMetrics *outMetrics)`**: Primary entry point for querying hardware metrics for an auto-detected drive, BSD identifier, mount path, or substring query.
- **`DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount)`**: Enumerates all physical block storage devices across the system.
- **`DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen)`**: Resolves the mounted filesystem path for a block device using `IOObjectIsEqualTo` fast matching and APFS container resolution.
- **`DiskConvertNVMeTemperature(uint16_t tempRaw)`**: Converts 16-bit NVMe composite temperature to Celsius with Kelvin (`233K–423K`) and direct Celsius boundary validation.
- **`DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed)`**: Normalizes IOKit `Device Speed` enum codes (`0` to `5`) and raw bits/sec values to standardized bits per second.

### 2. [`DiskHealthBridge.c`](DiskHealthBridge.c)
Implements the hardware discovery and telemetry pipeline:
1. **Mount Point Resolution (`statfs` & `DiskFindMountForBlockDevice`)**:
   - Resolves a volume path (e.g., `/Volumes/MySSD` or `/`) or device query (`disk4`, product name, or serial number) to its BSD disk identifier (`diskXsY` or `diskX`).
2. **APFS Physical Store Traversal (`findParentBlockStorageDeviceRecursive`)**:
   - Synthesized APFS volumes (e.g., `/dev/disk3s1s1` or `/dev/disk6s2`) sit inside an `AppleAPFSContainer` virtual object in the IOKit tree and do not directly attach to hardware controllers.
   - `findParentBlockStorageDeviceRecursive` traverses parent services recursively using `IORegistryEntryGetParentIterator` to locate the underlying physical `IOMedia` whole disk, `IOBlockStorageDevice`, `IOUSBHostDevice`, or `IONVMeController`.
3. **128-Bit NVMe SMART Decoding (`nvmeLe128ToU64`)**:
   - Reads the 512-byte NVMe SMART/Health Information Log (`NVMeSMARTData`).
   - Properly inspects all 16 bytes of 128-bit little-endian fields (`Data Units Read`, `Data Units Written`, `Host Read Commands`, `Host Write Commands`, `Power Cycles`, `Power On Hours`, `Unsafe Shutdowns`, `Media Errors`), saturating to `UINT64_MAX` if the upper 64 bits are non-zero.
   - Converts composite Kelvin temperature to Celsius (`DiskConvertNVMeTemperature`) with sanity bounds checking (`-40°C` to `150°C`).
4. **USB & Bus Speed Negotiation (`inspectParentsForBusProperties`)**:
   - Inspects `UsbLinkSpeed`, `LinkSpeed`, and `Device Speed` properties across `IOUSBHostDevice` / `AppleUSBXHCI` ancestors to distinguish USB 1.1 Full Speed (`12 Mbps`), USB 2.0 High-Speed (`480 Mbps`), USB 3.0 SuperSpeed (`5 Gbps`), USB 3.1/3.2 SuperSpeedPlus (`10 Gbps`), and USB 3.2 Gen 2x2 (`20 Gbps`), or PCIe/Apple Fabric for internal drives.
